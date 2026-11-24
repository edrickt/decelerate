import AppKit
import Foundation

/// Owns every interaction with macOS pointer acceleration.
///
/// Mechanism (verified on macOS 26, see `Notes/acceleration-research.md` and
/// `Notes/acceleration-amount-research.md`): pointer acceleration is applied by
/// Apple's `IOHIDPointerScrollFilter` from system-wide parameters and per-service
/// curves. At 0% Decelerate installs a constant-gain user curve per pointer
/// service (`UserPointerAccelCurvesKey`), so raw deltas are multiplied by the
/// chosen speed and nothing else. For intermediate amounts it installs the
/// device's own macOS curve interpolated toward the identity line, and at 100%
/// (with Speed at 1x) it clears the override so the filter uses macOS's own
/// curve. The original positive parameter values are written back so the filter
/// keeps acceleration enabled and the curve in effect. The filter caches those
/// user curves per service and rebuilds its accelerator from them. Nothing is
/// intercepted, no TCC permission is needed and no latency is added.
///
/// Devices that only have a classic acceleration table (most third-party
/// mice) use the table's own linear interpolation between "identity" and
/// "full acceleration": scaling the acceleration index by the chosen amount is
/// exactly that blend, so no table rewriting is needed.
///
/// Design goals, in order:
///  1. The change happens inside the HID pipeline, so the pointer keeps
///     macOS's own behavior.
///  2. Settings re-apply on wake, on device attach, and whenever macOS
///     rewrites the parameters. Sleep/wake recreates the HID services, so the
///     event-system client is re-created and the apply is retried until the
///     devices are back (see `reapplyAfterEnvironmentChange`).
///  3. Originals are snapshotted and restored exactly, and the snapshot can
///     never be corrupted by Decelerate's own writes (see `captureOriginals`).
@MainActor
final class AccelerationController {
    static let shared = AccelerationController()

    /// 0% means straight 1:1 movement.
    static let noAcceleration = 0.0
    /// 100% means macOS's own acceleration, untouched.
    static let nativeAcceleration = 1.0

    private enum Threshold {
        static let linear = 0.005
        static let native = 0.995
    }

    private enum AlgorithmOverride {
        static let native: Int32 = 2
    }

    /// How a pointer class must be shaped, derived from the services that are
    /// actually visible right now.
    private enum Route: Equatable {
        /// The services expose parametric acceleration curves.
        case curves
        /// The services expose only the classic acceleration table.
        case indexScaling
        /// No device of this class is attached.
        case absent
        /// Services exist but their acceleration representation cannot be read.
        /// This is what a stale event-system enumeration looks like after
        /// sleep/wake. Never guess a route here: applying the classic
        /// acceleration-index scaling to a curve-based device silently changes
        /// the pointer feel instead of failing.
        case unresolved
    }

    private let parameters: HIDPointerControl
    private let bridge: HIDServiceBridge
    private let scanner: HIDDeviceScanner
    private let store: PreferencesStore

    private var desired: [PointerClass: CategoryPreferences] = [:]
    /// Original IOFixed acceleration values per parameter key.
    private var originals: [String: Int32] = [:]
    /// Original IOFixed scroll-acceleration values per parameter key.
    private var scrollOriginals: [String: Int32] = [:]
    /// Values written by this controller (persisted), so its own writes are not
    /// mistaken for external changes or for the user's original setting.
    private var lastWritten: [String: Int32] = [:]
    /// Scroll values written by this controller (persisted), same protection.
    private var scrollLastWritten: [String: Int32] = [:]
    /// Snapshots last handed to `UserDefaults`, so an unchanged set is not
    /// re-encoded and rewritten. Every `persist*` call is a JSON encode plus a
    /// defaults write on the main thread, and a slider drag used to trigger one
    /// per HID parameter key plus four more per apply.
    private var persistedOriginals: [String: Int32]?
    private var persistedWrites: [String: Int32]?
    private var persistedScrollOriginals: [String: Int32]?
    private var persistedScrollWrites: [String: Int32]?
    /// True while a multi-key apply or restore is running: per-key persistence
    /// is deferred so the snapshots are written once at the end instead of once
    /// per key.
    private var isBatchingPersistence = false
    private var isReapplying = false
    private var isTerminating = false
    /// While a re-apply is writing parameters, property-change callbacks are
    /// echoes of our own writes and must not be mistaken for user changes.
    private var suppressExternalChangesUntil = Date.distantPast
    private var changeHandler: (() -> Void)?
    private var wakeObservers: [NSObjectProtocol] = []

    /// Bounded backoff for re-applies while macOS re-registers the HID services
    /// after wake or attach. Total window is about 18 s, which covers the
    /// trackpad and a Bluetooth mouse coming back.
    private static let retryDelays: [TimeInterval] = [0.25, 0.75, 2, 5, 10]
    private var retryAttempt = 0
    private var retryWorkItem: DispatchWorkItem?
    /// Pointer classes that had HID services during the last apply. Used after
    /// wake: a class that had services before sleeping may briefly look absent
    /// while macOS re-registers the device, and only such classes are retried.
    private var classesWithServices: Set<PointerClass> = []
    private var retryMissingClasses: Set<PointerClass> = []
    /// True while running the last allowed retry. Used as the point where an
    /// unreadable acceleration representation is accepted as genuine (see
    /// `performApply`).
    private var isFinalRetryAttempt = false

    // MARK: - Applied-state verification

    /// Registry IDs of the pointer services the last fully accepted apply
    /// shaped. `UserPointerAccelCurvesKey` is write-only (it reads back nil even
    /// in the writing process), so the service identity is the only available
    /// proof that the curves are still attached to a live filter instance.
    /// The built-in trackpad replaces its HID service whenever it wakes from
    /// idle, and a replacement silently reverts the pointer to macOS's own
    /// curve: this is the recurring "deceleration stopped working" report.
    private var appliedFingerprint: Set<UInt64>?
    /// Service set the most recent apply was attempted for, successful or not.
    /// Used to back off instead of re-applying in a loop.
    private var lastAttemptFingerprint: Set<UInt64>?
    private var lastAttemptAt = Date.distantPast
    private var watchdogTimer: Timer?
    private var watchdogTicks = 0
    private var activationObservers: [NSObjectProtocol] = []
    /// An external parameter change that arrived inside the settling window and
    /// still has to be re-applied (see `deferExternalChange`).
    private var hasDeferredExternalChange = false
    private var deferredChangeWorkItem: DispatchWorkItem?

    /// How often the live pointer services are compared with the shaped ones.
    /// With all settings native the check does no work at all, and with an
    /// unchanged service set it only asks the kernel whether the shaped entries
    /// still exist (see `shapedServicesStillPresent`).
    private static let watchdogInterval: TimeInterval = 2
    /// Spacing between repair attempts for the *same* service set when the
    /// apply keeps failing; the retry series already covers the first ~18 s.
    private static let watchdogFailureBackoff: TimeInterval = 30
    /// Ticks between full re-enumerations even when every shaped service is
    /// still alive (about a minute). The cheap kernel check answers "did a
    /// shaped service disappear", which is the recurring revert; a full
    /// enumeration also notices a service that *appeared* without a device
    /// attach callback, and that does not need to be noticed within 2 s.
    private static let watchdogFullSweepTicks = 30

    private(set) var lastError: String?
    /// Retained for API stability: this implementation intercepts no input and
    /// therefore never needs a TCC permission.
    private(set) var needsPermission = false

    private init(store: PreferencesStore = PreferencesStore()) {
        self.store = store
        self.parameters = HIDPointerControl()
        self.bridge = HIDServiceBridge()
        self.scanner = HIDDeviceScanner()
        self.lastWritten = store.loadAccelerationWrites()
            .filter { Self.managedKeys.contains($0.key) }

        // Snapshot of the user's own acceleration values, so macOS can be put
        // back exactly. The macOS tracking-speed setting is the ground truth:
        // macOS keeps `com.apple.trackpad.scaling` / `com.apple.mouse.scaling`
        // in lockstep with the HID parameters. Prefer it when it exists so a
        // snapshot corrupted by an older build (which could capture
        // Decelerate's own index-scaled write as the "original") is repaired
        // instead of being restored.
        var loaded = store.loadAccelerationOriginals()
        for key in Self.managedKeys {
            if let setting = Self.macOSSettingRaw(forKey: key) {
                loaded[key] = setting
            } else if let stored = loaded[key], Self.isPlausibleOriginal(stored) {
                continue
            } else {
                loaded[key] = Self.fallbackValue(forKey: key)
            }
        }
        self.originals = loaded
        store.saveAccelerationOriginals(loaded)
        // Scroll snapshot: unlike pointer tracking speed there is no reliable
        // `com.apple.*` ground-truth pref for scroll (the historic
        // `com.apple.scrollwheel.scaling` key is absent on current macOS), so
        // the live value stands unless it is implausible.
        var scrollLoaded = store.loadScrollOriginals()
        for key in Self.managedScrollKeys {
            if let stored = scrollLoaded[key], Self.isPlausibleOriginal(stored) {
                continue
            } else {
                scrollLoaded[key] = Self.scrollFallbackValue(forKey: key)
            }
        }
        self.scrollOriginals = scrollLoaded
        store.saveScrollOriginals(scrollLoaded)
        self.scrollLastWritten = store.loadScrollWrites()
            .filter { Self.managedScrollKeys.contains($0.key) }
    }

    /// A stored/read acceleration value is a curve selector (IOFixed). The real
    /// range on macOS spans roughly 0.125…3.0; anything below 0.125 (e.g. the
    /// corrupt value 1) is not a user setting and must never be written back.
    private static func isPlausibleOriginal(_ raw: Int32) -> Bool {
        raw >= 8_192 && raw <= 196_608
    }

    /// The HID acceleration value that matches the user's macOS tracking-speed
    /// setting, when that setting exists. `UserDefaults.standard` also searches
    /// the global domain, so the `com.apple.*.scaling` key is visible here.
    private static func macOSSettingRaw(forKey key: String) -> Int32? {
        let defaultsKey = key == HIDPropertyKey.trackpadAcceleration
            ? "com.apple.trackpad.scaling"
            : "com.apple.mouse.scaling"
        guard let number = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber else {
            return nil
        }
        guard let raw = fixedScalingValue(number.doubleValue) else { return nil }
        return isPlausibleOriginal(raw) ? raw : nil
    }

    /// Converts a `com.apple.*.scaling` value to the IOFixed value the HID
    /// parameter uses, or nil when it is not a tracking-speed setting.
    ///
    /// `Int32(Double)` traps on NaN, on ±inf and on anything outside `Int32`,
    /// and these are ordinary global-domain user defaults: a script, a managed
    /// preferences profile, a backup restore or an older build can leave any
    /// value there. `init` reads all three managed keys, so an unvalidated
    /// conversion made the app unlaunchable. The bound is the documented upper
    /// end of the useful range and matches `isPlausibleOriginal`'s 196608 cap
    /// (3.0 × 65536), so it rejects exactly the values the caller rejects and
    /// nothing that could otherwise have been accepted.
    nonisolated static func fixedScalingValue(_ value: Double) -> Int32? {
        guard value.isFinite, abs(value) <= 3.0 else { return nil }
        return Int32((value * 65_536.0).rounded())
    }

    /// The value to hand back to macOS for a key, guaranteed to be sane.
    private func originalValue(forKey key: String) -> Int32 {
        if let setting = Self.macOSSettingRaw(forKey: key) { return setting }
        if let raw = originals[key], Self.isPlausibleOriginal(raw) { return raw }
        let derived = Self.fallbackValue(forKey: key)
        originals[key] = derived
        return derived
    }

    // MARK: - Mapping

    private static func parameterKeys(for pointerClass: PointerClass) -> [String] {
        switch pointerClass {
        case .trackpad: return [HIDPropertyKey.trackpadAcceleration]
        case .mouse: return [HIDPropertyKey.mouseAcceleration, HIDPropertyKey.pointerAcceleration]
        }
    }

    private static var managedKeys: [String] {
        PointerClass.allCases.flatMap { parameterKeys(for: $0) }
    }

    private static func pointerClass(forParameterKey key: String) -> PointerClass? {
        switch key {
        case HIDPropertyKey.trackpadAcceleration, HIDPropertyKey.trackpadScrollAcceleration:
            return .trackpad
        case HIDPropertyKey.mouseAcceleration, HIDPropertyKey.pointerAcceleration,
            HIDPropertyKey.mouseScrollAcceleration:
            return .mouse
        default:
            // `HIDScrollAcceleration` is intentionally absent: it is the
            // machine-wide scroll fallback, not a mouse setting.
            return nil
        }
    }

    // MARK: - Scroll mapping

    /// The scroll parameters each class is allowed to shape. Only the
    /// type-specific key belongs to a class; macOS uses the generic
    /// `HIDScrollAcceleration` for every device as a fallback, so shaping it
    /// from the mouse class would change trackpads too.
    private static func scrollParameterKeys(for pointerClass: PointerClass) -> [String] {
        switch pointerClass {
        case .trackpad: return [HIDPropertyKey.trackpadScrollAcceleration]
        case .mouse: return [HIDPropertyKey.mouseScrollAcceleration]
        }
    }

    /// Scroll parameters Decelerate snapshots and restores. The type-specific
    /// keys are the per-class shaping targets; the generic key is included only
    /// so a value written by an older build is handed back on restore. It is
    /// never shaped per class.
    private static var managedScrollKeys: [String] {
        [
            HIDPropertyKey.trackpadScrollAcceleration,
            HIDPropertyKey.mouseScrollAcceleration,
            HIDPropertyKey.scrollAcceleration,
        ]
    }

    private static func isScrollParameterKey(_ key: String) -> Bool {
        managedScrollKeys.contains(key)
    }

    /// Identity of the services an apply shaped. Registry ID 0 means "no
    /// registry entry", which cannot be compared or targeted, so it is ignored.
    private static func fingerprint(of services: [HIDPointerService]) -> Set<UInt64> {
        Set(services.map(\.registryID).filter { $0 != 0 })
    }

    /// Fallback scroll value when no snapshot survived. The macOS default on
    /// the machines measured so far is 0.3125 for every scroll key.
    private static func scrollFallbackValue(forKey _: String) -> Int32 {
        20_480
    }

    /// The scroll value to hand back to macOS for a key, guaranteed to be sane.
    private func scrollOriginalValue(forKey key: String) -> Int32 {
        if let raw = scrollOriginals[key], Self.isPlausibleOriginal(raw) { return raw }
        let derived = Self.scrollFallbackValue(forKey: key)
        scrollOriginals[key] = derived
        return derived
    }

    private static func fallbackValue(forKey key: String) -> Int32 {
        key == HIDPropertyKey.trackpadAcceleration
            ? HIDPointerParameter.trackpadFallback
            : HIDPointerParameter.mouseFallback
    }

    private static func pointerClass(for service: HIDPointerService) -> PointerClass {
        service.isTrackpad ? .trackpad : .mouse
    }

    /// Pointer class implied by a service's own scroll acceleration type. The
    /// scroll filter selects its acceleration value from
    /// `HIDScrollAccelerationType`, which can differ from the pointer type, so
    /// scroll shaping is routed by this instead of the pointer class.
    private static func scrollClass(for service: HIDPointerService) -> PointerClass? {
        switch service.scrollAccelerationType {
        case HIDPropertyKey.trackpadScrollAcceleration: return .trackpad
        case HIDPropertyKey.mouseScrollAcceleration: return .mouse
        default: return nil
        }
    }

    /// The services one class's scroll settings may touch. A service whose
    /// scroll type names the other class is never included, which is what keeps
    /// a Mouse setting off a Trackpad (and the reverse). Services without a
    /// scroll type fall back to their pointer class.
    private static func scrollServices(
        for pointerClass: PointerClass,
        in services: [HIDPointerService]
    ) -> [HIDPointerService] {
        services.filter { service in
            (scrollClass(for: service) ?? Self.pointerClass(for: service)) == pointerClass
        }
    }

    /// Scroll parameter keys another attached class resolves to. Shaping one of
    /// these would change that class too, so they are skipped.
    private static func scrollKeysResolvedByOtherClasses(
        than pointerClass: PointerClass,
        in services: [HIDPointerService]
    ) -> Set<String> {
        var keys: Set<String> = []
        for other in PointerClass.allCases where other != pointerClass {
            for service in scrollServices(for: other, in: services) {
                if let key = service.resolvedScrollParameterKey { keys.insert(key) }
            }
        }
        return keys
    }

    // MARK: - Devices

    func connectedDevices() -> [PointerDevice] {
        scanner.devices()
    }

    /// Starts observing devices, HID parameters and sleep/wake. `onChange` is
    /// called after the state may have changed (device attach/removal, wake, or
    /// the end of a retry series) so the UI can refresh devices and status.
    func startMonitoring(onChange: @escaping () -> Void) {
        changeHandler = onChange
        scanner.startMonitoring { [weak self] in
            OnMain.run {
                guard let self else { return }
                self.reapplyAfterEnvironmentChange(retryMissingDevices: false)
                self.changeHandler?()
            }
        }
        parameters.startObserving(keys: Self.managedKeys + Self.managedScrollKeys) { [weak self] key, raw in
            OnMain.run { self?.systemParameterChanged(key, raw) }
        }
        // Activation is a free extra moment to verify: the user just opened the
        // menu bar panel or Settings, which is exactly when they look at the
        // status, and a heal here is immediate instead of up to one tick later.
        let activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            OnMain.run { self?.verifyAppliedServices(reason: "app became active") }
        }
        activationObservers.append(activation)
        // Sleep/wake is the other important trigger: macOS recreates the HID
        // services and the built-in trackpad gets a new registry ID, so both the
        // service enumeration and the applied curves are lost.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                OnMain.run {
                    guard let self else { return }
                    DebugLog.write("environment: \(name.rawValue)")
                    self.reapplyAfterEnvironmentChange(retryMissingDevices: true)
                    self.changeHandler?()
                }
            }
            wakeObservers.append(observer)
        }
        // The safety net that ends the silent-revert class of bug: nothing
        // notifies this process when macOS replaces a pointer service (the
        // hardware device never went away, so the IOHIDManager callbacks stay
        // quiet, and no HID parameter changes either). Poll the service
        // identity instead and re-apply on any difference.
        startWatchdog()
    }

    /// Stop observing, then hand the original parameters back to macOS. Called
    /// on quit; callbacks that arrive during teardown are ignored so the app
    /// cannot re-apply settings after restoring them.
    func prepareForTermination() {
        isTerminating = true
        stopMonitoring()
        restoreSystemState()
    }

    func stopMonitoring() {
        scanner.stopMonitoring()
        for observer in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObservers.removeAll()
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers.removeAll()
        stopWatchdog()
        cancelRetries()
    }

    // MARK: - Apply

    /// Applies the desired acceleration amount for both pointer classes.
    /// Safe and cheap to call repeatedly; this is the entry point used to
    /// re-apply settings. If the HID services are not ready yet (the normal
    /// case right after wake, while macOS re-registers the devices), a bounded
    /// retry loop re-applies once they are.
    func apply(_ preferences: [PointerClass: CategoryPreferences]) {
        desired = preferences
        retryAttempt = 0
        attemptApply()
    }

    func reapply() {
        guard !desired.isEmpty, !isTerminating else { return }
        apply(desired)
    }

    /// Re-applies after the HID environment changed (wake, device attach,
    /// removal). The connections are replaced first: macOS re-creates the
    /// pointer services across sleep, and a client created before sleep keeps
    /// reporting the dead ones.
    ///
    /// `retryMissingDevices` is set on wake, where a pointer class can briefly
    /// look absent while macOS re-registers its devices.
    private func reapplyAfterEnvironmentChange(retryMissingDevices: Bool) {
        guard !desired.isEmpty, !isTerminating else { return }
        parameters.forceReopen()
        bridge.refresh()
        retryAttempt = 0
        isFinalRetryAttempt = false
        retryMissingClasses = retryMissingDevices ? classesWithServices : []
        DebugLog.write("re-apply: HID clients refreshed after environment change")
        attemptApply()
    }

    private func attemptApply() {
        guard !isTerminating else { return }
        isFinalRetryAttempt = retryAttempt >= Self.retryDelays.count
        let needsRetry = performApply()
        guard needsRetry else {
            let wasRetrying = retryAttempt > 0
            cancelRetries()
            // A retry series can end successfully after an earlier attempt
            // reported a failure; let the UI drop the stale error.
            if wasRetrying { changeHandler?() }
            return
        }
        guard retryAttempt < Self.retryDelays.count else {
            DebugLog.write("re-apply: retries exhausted, leaving the current parameters")
            retryWorkItem?.cancel()
            retryWorkItem = nil
            retryMissingClasses = []
            // An unresolved route only reports itself through `needsRetry`, so
            // with the retry window closed it is a real failure the UI has not
            // seen yet. Surface it instead of silently leaving macOS in charge.
            if lastError == nil {
                lastError = "Pointer acceleration could not be applied to a connected device."
            }
            changeHandler?()
            return
        }
        let delay = Self.retryDelays[retryAttempt]
        retryAttempt += 1
        DebugLog.write("re-apply: HID services not ready, retry \(retryAttempt) in \(delay)s")
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.parameters.reopenIfNeeded()
            self.bridge.refresh()
            self.attemptApply()
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelRetries() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryAttempt = 0
        retryMissingClasses = []
        isFinalRetryAttempt = false
    }

    // MARK: - Applied-state verification

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            OnMain.run { self?.verifyAppliedServices(reason: nil) }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        deferredChangeWorkItem?.cancel()
        deferredChangeWorkItem = nil
        hasDeferredExternalChange = false
    }

    /// True when a class is actually being shaped, i.e. when losing a HID
    /// service would change how the pointer or the wheel behaves.
    private var isShaping: Bool {
        desired.values.contains {
            !$0.isNative || abs($0.speedMultiplier - 1.0) >= 0.01 || !$0.isScrollNative
        }
    }

    /// Re-applies when the live pointer services are no longer the ones that
    /// were shaped. Cheap and idempotent: with an unchanged service set it only
    /// compares registry IDs and performs no HID writes.
    ///
    /// This exists because the loss is completely silent otherwise. macOS
    /// replaces a pointer service (the built-in trackpad does it on every wake
    /// from idle) and the per-service user curve goes with it, while the HID
    /// parameters stay exactly as Decelerate wrote them: no parameter callback
    /// fires, no device attach is reported, and the curves cannot be read back.
    /// The pointer silently falls back to macOS acceleration with the UI still
    /// reporting the settings as applied.
    private func verifyAppliedServices(reason: String?) {
        guard !desired.isEmpty, !isTerminating, !isReapplying, isShaping else { return }
        // A retry series is already re-applying; never race it.
        guard retryWorkItem == nil, retryAttempt == 0 else { return }

        // Cheap kernel check first, because re-reading the services is not
        // cheap: a fresh `IOHIDEventSystemClientCreate` measured 104–138 ms
        // (p50 114 ms) on this machine, and this used to run on the main thread
        // twice a second. A user curve is cached in the filter instance of one
        // service, so "every shaped registry entry still exists" is exactly
        // "the shaping is still in place", and the IORegistry answers that in
        // ~0.09 ms per service without a client. One full re-enumeration per
        // `watchdogFullSweepTicks` still runs, so a service that appears without
        // a device-attach callback is picked up within about a minute; a service
        // that *disappears* (the recurring revert) is still noticed within one
        // tick.
        if appliedFingerprint != nil {
            watchdogTicks += 1
            let scheduledSweep = watchdogTicks % Self.watchdogFullSweepTicks == 0
            if !scheduledSweep, shapedServicesStillPresent() { return }
        }

        // A state change is either a removed shaped service or a scheduled
        // sweep, so the enumeration has to look through a freshly created
        // connection: a client created earlier can keep returning service
        // objects macOS has already replaced, and "the client cannot see the
        // new service" is exactly how a reverted pointer stays unnoticed.
        bridge.refresh()
        let live = bridge.pointerServiceFingerprint()
        guard live != appliedFingerprint else { return }
        if live == lastAttemptFingerprint,
           Date().timeIntervalSince(lastAttemptAt) < Self.watchdogFailureBackoff {
            // Same service set as the last attempt and it has not stuck yet:
            // the retry series owns that failure, so do not hammer it.
            return
        }
        if live.isEmpty {
            // No pointer services from a fresh connection is a dead event
            // system (WindowServer restarting), not a Mac without devices; an
            // apply that legitimately shaped nothing records an empty set and
            // is not retried here.
            heal("the HID event system returned no pointer services", reason: reason)
            return
        }
        let shaped = appliedFingerprint.map { "\($0.count)" } ?? "none"
        heal("HID services changed (shaped \(shaped), live \(live.count))", reason: reason)
    }

    /// True when every pointer service the last fully accepted apply shaped
    /// still has a live IORegistry entry, i.e. the filter instances carrying the
    /// user curves are the live ones. Returns false when no apply has been
    /// accepted yet: without a shaped set there is nothing to ask about, and the
    /// caller falls back to a full enumeration.
    private func shapedServicesStillPresent() -> Bool {
        guard let appliedFingerprint, !appliedFingerprint.isEmpty else { return false }
        return bridge.registryEntriesExist(appliedFingerprint)
    }

    /// Re-creates the HID connections and applies again. Used when the services
    /// that were shaped are no longer the live ones.
    private func heal(_ message: String, reason: String?) {
        let suffix = reason.map { " [\($0)]" } ?? ""
        DebugLog.write("watchdog: \(message)\(suffix); re-applying")
        parameters.forceReopen()
        bridge.refresh()
        retryAttempt = 0
        isFinalRetryAttempt = false
        retryMissingClasses = []
        attemptApply()
        changeHandler?()
    }

    /// Re-applies an external parameter change that landed inside the settling
    /// window. macOS rewrites these parameters exactly when it is creating a HID
    /// service, which is the same moment Decelerate applies its own values, so
    /// dropping the callback at that point leaves macOS's value in place while
    /// the app believes it already shaped the pointer.
    private func deferExternalChange() {
        hasDeferredExternalChange = true
        guard deferredChangeWorkItem == nil else { return }
        let delay = max(0.05, suppressExternalChangesUntil.timeIntervalSinceNow) + 0.05
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredChangeWorkItem = nil
            guard self.hasDeferredExternalChange, !self.isTerminating else { return }
            self.hasDeferredExternalChange = false
            DebugLog.write("apply: external parameter change arrived while settling, re-applying")
            self.attemptApply()
            self.changeHandler?()
        }
        deferredChangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Applies the desired state once. Returns true when the HID services were
    /// not ready (or a write was rejected), i.e. another attempt may succeed.
    private func performApply() -> Bool {
        guard !desired.isEmpty else { return false }
        guard parameters.isAvailable else {
            lastError = "The HID system is unavailable on this Mac."
            return true
        }
        guard bridge.isAvailable else {
            // Without the full event-system client the per-service curves can
            // never be installed or cleared, so report the failure instead of
            // pretending the settings were applied.
            lastError = "The HID event system is unavailable on this Mac."
            return true
        }
        captureOriginalsIfNeeded()
        captureScrollOriginalsIfNeeded()
        suppressExternalChangesUntil = Date().addingTimeInterval(0.75)
        isBatchingPersistence = true
        defer {
            isBatchingPersistence = false
            flushPersistence()
        }

        let services = bridge.pointerServices()
        let fingerprint = Self.fingerprint(of: services)
        lastAttemptFingerprint = fingerprint
        lastAttemptAt = Date()
        var rejected = false
        var needsRetry = false
        var observedClasses: Set<PointerClass> = []

        for pointerClass in PointerClass.allCases {
            let category = desired[pointerClass] ?? CategoryPreferences()
            let amount = category.accelerationAmount
            let speed = category.speedMultiplier
            let classServices = services.filter { Self.pointerClass(for: $0) == pointerClass }
            if !classServices.isEmpty { observedClasses.insert(pointerClass) }
            let route = Self.route(for: classServices)
            let keys = Self.parameterKeys(for: pointerClass)
            DebugLog.write("apply: \(pointerClass) amount=\(amount) speed=\(speed) route=\(route) services=\(classServices.count)")

            // Scroll shaping is independent of the pointer route, so it runs
            // before the pointer logic: the pointer path can skip a class (0%
            // pointer acceleration, unresolved curves), and that must never
            // leave the class's scroll settings unapplied.
            let scrollResult = applyScroll(
                category,
                for: pointerClass,
                on: Self.scrollServices(for: pointerClass, in: services),
                avoiding: Self.scrollKeysResolvedByOtherClasses(than: pointerClass, in: services)
            )
            rejected = rejected || scrollResult.rejected
            needsRetry = needsRetry || scrollResult.needsRetry

            // Which representation each service of this class uses. The
            // decision is per service: a table-only mouse attached next to a
            // curve-capable one must not pull the whole class onto the
            // index-scaling path, which used to clear the curve device's user
            // curve (so it silently got macOS's native acceleration) and left
            // its Speed control inert.
            let classHasCurves = classServices.contains { $0.hasNativeCurves }
            let curveServices = classServices.filter { $0.hasNativeCurves }
            var tableServices = classServices.filter { !$0.hasNativeCurves && $0.hasAccelerationTable }
            var unreadableServices = classServices.filter {
                !$0.hasNativeCurves && !$0.hasAccelerationTable
            }

            // Enumeration is stale (right after wake): leave those services'
            // parameters alone rather than guessing a representation. The
            // trackpad class is always curve-based (built-in and Magic
            // Trackpads), so a trackpad whose curves cannot be read is stale,
            // never a table device, and must never be index-scaled.
            //
            // The mouse class is where table-only devices live, so it accepts
            // the table interpretation -- but only on an independent signal
            // that the service is real and settled, never because "the table is
            // unreadable too". A service still being created, or a dead object
            // from a client created before sleep, reports neither curves nor a
            // table, which is exactly what a USB mouse with neither
            // representation reports (verified: the filter then falls back to
            // its compiled-in default table). Those two cases are told apart by
            // the IORegistry entry: a live entry means the service is real (the
            // curve and table readers already fall back to that same entry, so
            // an unreadable representation is genuine for it), while a dead or
            // missing entry means the enumeration is stale and only the final
            // retry may give up and treat it as a table device.
            if !unreadableServices.isEmpty {
                let settled = unreadableServices.allSatisfy(\.hasLiveRegistryEntry)
                let acceptAsTable = pointerClass == .mouse && !classHasCurves
                    && (settled || isFinalRetryAttempt)
                if acceptAsTable {
                    DebugLog.write("apply: \(pointerClass) unreadable curves, using table scaling")
                    tableServices += unreadableServices
                    unreadableServices = []
                } else {
                    // Stale enumeration: do not guess a representation and do
                    // not touch this class's parameters; the retry series
                    // re-enumerates through a fresh client instead.
                    needsRetry = true
                    continue
                }
            }

            if classServices.isEmpty {
                // No device of this class is attached: hand the parameters
                // back so macOS stays sane without it, and retry when the
                // device is (or should be) present but has no HID service yet.
                for key in keys {
                    if !write(key, originalValue(forKey: key)) {
                        rejected = true
                        needsRetry = true
                    }
                }
                if !clearOverrides(on: classServices) { rejected = true }
                if amount < Threshold.native, retryMissingClasses.contains(pointerClass) {
                    needsRetry = true
                }
                continue
            }

            if amount <= Threshold.linear {
                // No acceleration: a constant-gain user curve. User curves take
                // priority over both the parametric curves and the classic
                // table, so this works for every device class.
                //
                // Parameters first, curve last. A global parameter write can
                // rebuild the filter and drop the curve it has cached per
                // service, so the curve has to be the final write; doing this
                // in the other order is how a correct curve gets wiped right
                // after it is installed.
                for key in keys {
                    if !write(key, originalValue(forKey: key)) {
                        rejected = true
                        needsRetry = true
                    }
                }
                if !installConstantCurves(speed: speed, on: classServices) {
                    rejected = true
                    needsRetry = true
                }
                if classServices.isEmpty, retryMissingClasses.contains(pointerClass) {
                    needsRetry = true
                }
                continue
            }

            if !curveServices.isEmpty {
                // Curves first-class: the services that have them get the blend
                // (or the hand-back), and the class parameter keeps its
                // original index. Parameters first, curves last (see the 0%
                // branch above): curves only take effect while acceleration
                // itself is enabled, and a parameter write must never follow the
                // curve install. Never clear a service that is about to receive
                // a curve.
                for key in keys {
                    if !write(key, originalValue(forKey: key)) {
                        rejected = true
                        needsRetry = true
                    }
                }
                if amount >= Threshold.native, abs(speed - 1.0) < 0.01 {
                    // Exactly macOS's own curve: hand control back.
                    if !clearOverrides(on: curveServices) { rejected = true }
                } else {
                    if !installBlendedCurves(amount, speed: speed, on: curveServices) {
                        rejected = true
                        needsRetry = true
                    }
                }
                if !tableServices.isEmpty {
                    // A mixed class cannot index-scale: the parameter is shared,
                    // and scaling it would change which entry of the curve
                    // device's own blended array the filter selects. The table
                    // devices therefore keep macOS's acceleration, and only a
                    // leftover user curve of ours (0% or an earlier session) is
                    // cleared from them.
                    if !clearOverrides(on: tableServices) { rejected = true }
                    DebugLog.write(
                        "apply: \(pointerClass) table-only service(s) keep macOS acceleration: "
                            + tableServices.map(\.product).joined(separator: ", ")
                    )
                }
                continue
            }

            // Table-only devices (most third-party mice) do not expose
            // parametric curves; amount is the table's own interpolation
            // (scale the acceleration index). Speed cannot be scaled there.
            if amount >= Threshold.native {
                for key in keys {
                    if !write(key, originalValue(forKey: key)) {
                        rejected = true
                        needsRetry = true
                    }
                }
            } else {
                for key in keys {
                    if !writeScaled(key, amount: amount) {
                        rejected = true
                        needsRetry = true
                    }
                }
            }
            // A leftover user curve would override the scaled index.
            if !clearOverrides(on: tableServices) { rejected = true }
        }

        classesWithServices = observedClasses

        persistOriginals()
        persistScrollOriginals()
        // Only a fully accepted apply counts as "these services are shaped".
        // A rejected write or a pending retry leaves the verification state
        // unknown, so the watchdog gives it another chance.
        appliedFingerprint = (needsRetry || rejected) ? nil : fingerprint
        if let appliedFingerprint {
            let ids = appliedFingerprint.sorted().map { String($0, radix: 16) }.joined(separator: ", ")
            DebugLog.write("apply: shaped \(appliedFingerprint.count) service(s): \(ids)")
        }
        lastError = rejected ? "macOS rejected a pointer acceleration setting." : nil
        if rejected {
            DebugLog.write("apply: macOS rejected one or more pointer parameter writes")
        }
        return needsRetry || rejected
    }

    /// Restores the user's original acceleration. Used when turning the feature
    /// off and when the app quits, so quitting never leaves the Mac patched.
    func restoreSystemState() {
        cancelRetries()
        // A wake notification can be missed, so never restore through possibly
        // stale connections.
        parameters.forceReopen()
        bridge.refresh()
        // A restore that cannot reach the event-system services cannot clear a
        // cached user curve, so it must not report success and drop the
        // snapshot; keep it for the next launch to repair.
        var rejected = !bridge.isAvailable
        isBatchingPersistence = true
        defer {
            isBatchingPersistence = false
            flushPersistence()
        }
        // Clear the per-service user curves through the event system first; that
        // path does not need the IOHIDSystem parameter connection, so a failed
        // parameter reopen cannot leave the pointer shaped.
        let services = bridge.pointerServices()
        for service in services {
            if !clearOverrides(on: [service]) { rejected = true }
            if !clearScrollOverrides(on: [service]) { rejected = true }
        }
        if parameters.isAvailable {
            for key in Self.managedKeys {
                if !write(key, originalValue(forKey: key)) { rejected = true }
            }
            for key in Self.managedScrollKeys {
                if !writeScroll(key, scrollOriginalValue(forKey: key)) { rejected = true }
            }
        } else {
            rejected = true
        }
        lastError = rejected ? "Could not restore the original pointer acceleration." : nil
        guard !rejected else {
            // The Mac may still be patched, so the snapshot is the only data
            // that can repair it. Keep it, together with the last-written marks
            // (which now always describe the live value), for the next launch.
            persistOriginals()
            persistWrites()
            persistScrollOriginals()
            persistScrollWrites()
            return
        }
        originals.removeAll()
        lastWritten.removeAll()
        scrollOriginals.removeAll()
        scrollLastWritten.removeAll()
        persistOriginals()
        persistWrites()
        persistScrollOriginals()
        persistScrollWrites()
    }

    // MARK: - Routing

    /// Summary of how a class is shaped, for the debug log only.
    ///
    /// The real decision is per service (see `performApply`): a class can hold
    /// curve-capable and table-only devices at the same time, and shaping each
    /// one through its own representation is what keeps one device's limitations
    /// from changing another's feel. This label reports a class as `.curves` only
    /// when every service has curves, `.indexScaling` only when every service is
    /// table-only, and `.unresolved` for the mixed or unreadable cases.
    ///
    /// Parametric curves exist on Apple trackpads (and some Apple mice). Devices
    /// without them use the classic acceleration table, whose interpolation can
    /// be driven by scaling the acceleration index instead.
    private static func route(for services: [HIDPointerService]) -> Route {
        guard !services.isEmpty else { return .absent }
        if services.allSatisfy({ $0.hasNativeCurves }) { return .curves }
        let tableOnly = services.filter { !$0.hasNativeCurves }
        if tableOnly.allSatisfy({ $0.hasAccelerationTable }) { return .indexScaling }
        return .unresolved
    }

    // MARK: - Curve installation

    private func installBlendedCurves(
        _ amount: Double,
        speed: Double,
        on services: [HIDPointerService]
    ) -> Bool {
        guard !services.isEmpty else { return true }
        var ok = true
        for service in services {
            // A service without readable natives must fail loudly (retry, then
            // surface an error) rather than silently shaping nothing while the
            // app reports success.
            guard let curves = service.nativeCurves, !curves.isEmpty else {
                DebugLog.write("apply: missing native curves for \(service.product)")
                ok = false
                continue
            }
            let blended = AccelerationCurveBuilder.curves(curves, factor: amount, speed: speed)
            if !bridge.setCurves(blended, on: service.ref) {
                ok = false
            }
        }
        return ok
    }

    /// Installs a pure constant-gain curve (no acceleration) at the chosen
    /// speed. Works for parametric devices and for table-only devices alike,
    /// because user curves take priority over both native representations.
    private func installConstantCurves(speed: Double, on services: [HIDPointerService]) -> Bool {
        guard !services.isEmpty else { return true }
        var ok = true
        for service in services {
            let source = service.nativeCurves ?? [[HIDCurveKey.index: 0]]
            let constant = AccelerationCurveBuilder.curves(source, factor: 0, speed: speed)
            if !bridge.setCurves(constant, on: service.ref) {
                ok = false
            }
        }
        return ok
    }

    /// Removes Decelerate's per-service curve override, if any.
    ///
    /// `UserPointerAccelCurvesKey` is write-only, so there is no way to read
    /// back whether a service still carries an override: the in-memory tracking
    /// that used to gate this call is lost on an abnormal exit, and a user curve
    /// cached in WindowServer would then keep shaping the pointer while the app
    /// reports macOS's native curve. Clearing unconditionally is a no-op for the
    /// filter when no override is installed, so it is the safe default.
    private func clearOverrides(on services: [HIDPointerService]) -> Bool {
        var ok = true
        for service in services {
            if !bridge.clearCurves(on: service.ref) { ok = false }
            if !bridge.setAlgorithmOverride(AlgorithmOverride.native, on: service.ref) { ok = false }
        }
        return ok
    }

    // MARK: - Scroll

    /// Applies the desired scroll state for one pointer class. Returns whether
    /// a write was rejected and whether another attempt may succeed.
    ///
    /// The scroll pipeline mirrors the pointer one: devices with native
    /// parametric scroll curves (Apple trackpads) are shaped by blending those
    /// curves, while table-only devices (plain USB mice) are shaped by scaling
    /// the scroll acceleration index, which is exactly the default table's own
    /// interpolation. Inversion installs a constant negative-gain curve per
    /// service, so a mouse wheel can run opposite the trackpad without touching
    /// macOS's single global Natural-scroll switch and without intercepting any
    /// events; because that curve is linear, `invertScroll` replaces the Scroll
    /// amount instead of shaping it, and the UI says so.
    ///
    /// Class isolation is structural: `classServices` only contains services
    /// whose own `HIDScrollAccelerationType` names this class, and parameter
    /// writes are limited to this class's type-specific key, never the shared
    /// generic one. A Mouse setting therefore cannot move a Trackpad.
    private func applyScroll(
        _ category: CategoryPreferences,
        for pointerClass: PointerClass,
        on classServices: [HIDPointerService],
        avoiding sharedKeys: Set<String>
    ) -> (rejected: Bool, needsRetry: Bool) {
        let amount = category.scrollAccelerationAmount
        let speed = category.scrollSpeedMultiplier
        let invert = category.invertScroll
        // Only the class's own type key is a shaping target. A key another
        // attached class resolves to (including the machine-wide generic key)
        // is skipped so this class's setting can never move the other device.
        let keys = Self.scrollParameterKeys(for: pointerClass)
        let shapeKeys = keys.filter { !sharedKeys.contains($0) }
        DebugLog.write(
            "apply scroll: \(pointerClass) amount=\(amount) speed=\(speed) invert=\(invert)"
                + " keys=\(shapeKeys) skipped=\(keys.filter { sharedKeys.contains($0) })"
                + " services=\(classServices.map { "\($0.product):\($0.resolvedScrollParameterKey ?? "generic")" })"
        )

        if category.isScrollNative {
            // Exactly macOS's own scrolling: hand control back.
            var rejected = false
            for key in shapeKeys {
                if !writeScroll(key, scrollOriginalValue(forKey: key)) {
                    rejected = true
                }
            }
            if !clearScrollOverrides(on: classServices) { rejected = true }
            return (rejected, rejected)
        }

        if classServices.isEmpty {
            // No device of this class is attached: hand the scroll parameters
            // back so macOS stays sane without it.
            var rejected = false
            for key in shapeKeys {
                if !writeScroll(key, scrollOriginalValue(forKey: key)) {
                    rejected = true
                }
            }
            if !clearScrollOverrides(on: classServices) { rejected = true }
            let needsRetry = retryMissingClasses.contains(pointerClass)
            return (rejected, rejected || needsRetry)
        }

        let hasCurves = classServices.allSatisfy { $0.hasNativeScrollCurves }
        let useCurves = hasCurves || invert || abs(speed - 1.0) >= 0.01
        if useCurves {
            // User scroll curves take priority over both the parametric curves
            // and the default table, so this also works for table-only mice.
            // The curves are written per service, so they only ever shape the
            // devices in this class.
            var rejected = false
            var needsRetry = false
            // Scroll parameters first, curves last, for the same reason as the
            // pointer path: a parameter write can rebuild the filter and drop
            // the per-service cached curve.
            for key in shapeKeys {
                if !writeScroll(key, scrollOriginalValue(forKey: key)) {
                    rejected = true
                    needsRetry = true
                }
            }
            // An inverted blended curve cannot work: negating the coefficients
            // of the `sqrt` tail and of the even powers does not change their
            // sign, so the inverted direction would only hold at very low speed
            // and the tail would always scroll the original way. `invert`
            // therefore always installs the constant negative-gain curve, and
            // the Scroll amount is not applied (the UI states that).
            if !invert, hasCurves {
                if !installBlendedScrollCurves(amount, speed: speed, on: classServices) {
                    rejected = true
                    needsRetry = true
                }
            } else if !installConstantScrollCurves(speed: speed, invert: invert, on: classServices) {
                rejected = true
                needsRetry = true
            }
            return (rejected, needsRetry)
        }

        // Table-only device at 1x without inversion: scale the scroll
        // acceleration index, exactly like the pointer table path.
        var rejected = false
        var needsRetry = false
        if amount >= Threshold.native {
            for key in shapeKeys {
                if !writeScroll(key, scrollOriginalValue(forKey: key)) {
                    rejected = true
                    needsRetry = true
                }
            }
        } else {
            for key in shapeKeys {
                if !writeScrollScaled(key, amount: amount) {
                    rejected = true
                    needsRetry = true
                }
            }
        }
        if !clearScrollOverrides(on: classServices) { rejected = true }
        return (rejected, needsRetry)
    }

    private func installBlendedScrollCurves(
        _ amount: Double,
        speed: Double,
        on services: [HIDPointerService]
    ) -> Bool {
        guard !services.isEmpty else { return true }
        var ok = true
        for service in services {
            guard let curves = service.nativeScrollCurves, !curves.isEmpty else {
                DebugLog.write("apply scroll: missing native scroll curves for \(service.product)")
                ok = false
                continue
            }
            let blended = AccelerationCurveBuilder.curves(curves, factor: amount, speed: speed)
            if !bridge.setScrollCurves(blended, on: service.ref) {
                ok = false
            }
        }
        return ok
    }

    /// Installs a pure constant-gain scroll curve at the chosen speed and
    /// direction. Works for parametric devices and for table-only devices
    /// alike, because user scroll curves take priority over both native
    /// representations. This is the only inverted curve the filter can be given:
    /// see `AccelerationCurveBuilder.constantCurves`.
    private func installConstantScrollCurves(speed: Double, invert: Bool, on services: [HIDPointerService]) -> Bool {
        guard !services.isEmpty else { return true }
        var ok = true
        for service in services {
            let source = service.nativeScrollCurves ?? [[HIDCurveKey.index: 0]]
            let constant = AccelerationCurveBuilder.constantCurves(source, speed: speed, invert: invert)
            if !bridge.setScrollCurves(constant, on: service.ref) {
                ok = false
            }
        }
        return ok
    }

    private func clearScrollOverrides(on services: [HIDPointerService]) -> Bool {
        var ok = true
        for service in services {
            if !bridge.clearScrollCurves(on: service.ref) { ok = false }
        }
        return ok
    }

    @discardableResult
    private func writeScroll(_ key: String, _ raw: Int32) -> Bool {
        let live = parameters.readRaw(key)
        if live == raw {
            scrollLastWritten[key] = raw
            persistScrollWrites()
            return true
        }
        let wrote = parameters.writeRaw(key, raw)
        if wrote {
            scrollLastWritten[key] = raw
        } else if let live {
            scrollLastWritten[key] = live
        }
        persistScrollWrites()
        return wrote
    }

    /// Table-based scroll path: scale the scroll acceleration index by the
    /// amount, mirroring the pointer table path. No plausibility floor: scaled
    /// writes are fenced off from the snapshot.
    private func writeScrollScaled(_ key: String, amount: Double) -> Bool {
        let base = scrollOriginalValue(forKey: key)
        let scaled = max(1, Int32((Double(base) * amount).rounded()))
        return writeScroll(key, min(scaled, base))
    }

    private func captureScrollOriginalsIfNeeded() {
        var captured = false
        for key in Self.managedScrollKeys {
            guard let raw = parameters.readRaw(key), Self.isPlausibleOriginal(raw) else { continue }
            // Never mistake Decelerate's own applied value for the user's
            // original.
            if scrollLastWritten[key] == raw { continue }
            if scrollOriginals[key] != raw {
                scrollOriginals[key] = raw
                captured = true
            }
        }
        if captured { persistScrollOriginals() }
    }

    private func persistScrollOriginals() {
        guard !isBatchingPersistence, persistedScrollOriginals != scrollOriginals else { return }
        persistedScrollOriginals = scrollOriginals
        if scrollOriginals.isEmpty {
            store.clearScrollOriginals()
        } else {
            store.saveScrollOriginals(scrollOriginals)
        }
    }

    private func persistScrollWrites() {
        guard !isBatchingPersistence, persistedScrollWrites != scrollLastWritten else { return }
        persistedScrollWrites = scrollLastWritten
        if scrollLastWritten.isEmpty {
            store.clearScrollWrites()
        } else {
            store.saveScrollWrites(scrollLastWritten)
        }
    }

    // MARK: - Parameters

    @discardableResult
    private func write(_ key: String, _ raw: Int32) -> Bool {
        // Avoid churning the HID pipeline when the value is already correct;
        // curve changes trigger their own rebuild.
        let live = parameters.readRaw(key)
        if live == raw {
            lastWritten[key] = raw
            persistWrites()
            return true
        }
        let wrote = parameters.writeRaw(key, raw)
        // Record the value that is actually live, not the requested one: on a
        // rejected write the previous value is still in place, and for a
        // table-only mouse that previous value can be Decelerate's own scaled
        // index. Marking the rejected target instead would let the next
        // launch's `captureOriginalsIfNeeded` adopt the scaled value as the
        // user's original and compound the scaling on every relaunch.
        if wrote {
            lastWritten[key] = raw
        } else if let live {
            lastWritten[key] = live
        }
        persistWrites()
        return wrote
    }

    /// Table-based devices: the table interpolates linearly between its identity
    /// entry (acceleration index 0) and its full-acceleration entry, so scaling
    /// the index by the amount is exactly "amount of acceleration".
    private func writeScaled(_ key: String, amount: Double) -> Bool {
        let base = originalValue(forKey: key)
        // No plausibility floor here: small amounts must interpolate near the
        // table's identity entry, and flooring at 8192 froze the whole
        // 0-18% slider range at one value. Scaled writes are still fenced off
        // from the snapshot (implausible reads are never adopted as originals,
        // and lastWritten marks our own output).
        let scaled = max(1, Int32((Double(base) * amount).rounded()))
        // Scaling can only reduce the index, never raise it.
        return write(key, min(scaled, base))
    }

    // MARK: - Snapshot

    private func captureOriginalsIfNeeded() {
        var captured = false
        for key in Self.managedKeys {
            guard let raw = parameters.readRaw(key), Self.isPlausibleOriginal(raw) else { continue }
            // Never mistake Decelerate's own applied value for the user's
            // original. For table-based devices the live parameter is our
            // scaled write; capturing it would compound the scaling on every
            // re-apply and every relaunch, and make quit restore the wrong
            // value.
            if lastWritten[key] == raw { continue }
            // When macOS exposes the tracking-speed setting it is authoritative
            // and the snapshot must not drift away from it.
            if Self.macOSSettingRaw(forKey: key) != nil { continue }
            if originals[key] != raw {
                originals[key] = raw
                captured = true
            }
        }
        if captured { persistOriginals() }
    }

    private func persistOriginals() {
        guard !isBatchingPersistence, persistedOriginals != originals else { return }
        persistedOriginals = originals
        if originals.isEmpty {
            store.clearAccelerationOriginals()
        } else {
            store.saveAccelerationOriginals(originals)
        }
    }

    private func persistWrites() {
        guard !isBatchingPersistence, persistedWrites != lastWritten else { return }
        persistedWrites = lastWritten
        if lastWritten.isEmpty {
            store.clearAccelerationWrites()
        } else {
            store.saveAccelerationWrites(lastWritten)
        }
    }

    /// Writes every snapshot once. Called when a batched operation ends.
    private func flushPersistence() {
        persistOriginals()
        persistWrites()
        persistScrollOriginals()
        persistScrollWrites()
    }

    // MARK: - External changes

    private func systemParameterChanged(_ key: String, _ raw: Int32) {
        guard !isTerminating else { return }
        // Our own writes echo back; ignore them. Anything that arrives during
        // the settling window is deferred instead of ignored: macOS rewrites
        // these parameters while it creates a HID service, which is exactly
        // when our own apply is settling.
        if lastWritten[key] == raw { return }
        if scrollLastWritten[key] == raw { return }
        if Date() < suppressExternalChangesUntil {
            // macOS rewrites these parameters exactly when it is creating a HID
            // service, which is the same moment our own apply is settling. A
            // dropped callback here leaves macOS's value in place while the app
            // believes it already shaped the pointer, so re-apply once the
            // window closes instead of ignoring it.
            deferExternalChange()
            return
        }
        guard let pointerClass = Self.pointerClass(forParameterKey: key) else { return }
        // A genuine external change is a good moment to re-enumerate: wake
        // rewrites can arrive around the same time, and a decision about the
        // shaping route must never be made from a stale event-system client.
        // Re-enumerating costs ~100 ms (the client create), so it is skipped
        // while every shaped service is still alive; a dead service is reported
        // below as an unreadable representation, which the retry series answers
        // with the refresh this used to do unconditionally.
        if !shapedServicesStillPresent() {
            bridge.refresh()
        }
        if Self.isScrollParameterKey(key) {
            guard let category = desired[pointerClass], !category.isScrollNative else { return }
            if Self.isPlausibleOriginal(raw) {
                scrollOriginals[key] = raw
                persistScrollOriginals()
                // A new base index has to be rescaled on the table path;
                // curve paths keep the originals written back and need nothing.
                let services = bridge.pointerServices()
                let classServices = Self.scrollServices(for: pointerClass, in: services)
                let tablePath = !classServices.allSatisfy { $0.hasNativeScrollCurves }
                let sharedKeys = Self.scrollKeysResolvedByOtherClasses(than: pointerClass, in: services)
                if tablePath, !sharedKeys.contains(key), !category.invertScroll,
                   abs(category.scrollSpeedMultiplier - 1.0) < 0.01,
                   category.scrollAccelerationAmount < Threshold.native {
                    _ = writeScrollScaled(key, amount: category.scrollAccelerationAmount)
                }
            }
        } else {
            // Speed alone at 100% acceleration is still a real override, so the
            // "is this class shaped at all" question -- not just the amount --
            // decides whether an external rewrite has to be answered.
            guard let category = desired[pointerClass],
                  !category.isNative || abs(category.speedMultiplier - 1.0) >= 0.01 else { return }
            if Self.isPlausibleOriginal(raw) {
                originals[key] = raw
                persistOriginals()
                // For index-scaled classes, a new base index has to be rescaled.
                // A class with any curve-capable service keeps its index: the
                // curve devices select their entry from it (see `performApply`).
                let classServices = bridge.pointerServices().filter {
                    Self.pointerClass(for: $0) == pointerClass
                }
                if !classServices.isEmpty, !classServices.contains(where: { $0.hasNativeCurves }) {
                    _ = writeScaled(key, amount: category.accelerationAmount)
                }
            }
        }
        guard !isReapplying else { return }
        isReapplying = true
        Task { @MainActor in
            apply(desired)
            try? await Task.sleep(nanoseconds: 400_000_000)
            isReapplying = false
        }
    }

    func refreshPermissionStatus() {
        needsPermission = false
    }

    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        true
    }

    // MARK: - Diagnostics

    /// Compact description of the live parameter values, used by Settings.
    var parameterSummary: String {
        func describe(_ raw: Int32?) -> String {
            guard let raw else { return "unknown" }
            return raw < 0 ? "1:1 (acceleration off)" : "accelerated (\(HIDPropertyKey.fixedString(raw)))"
        }
        let trackpad = parameters.readRaw(HIDPropertyKey.trackpadAcceleration)
        let mouse = parameters.readRaw(HIDPropertyKey.mouseAcceleration)
        let trackpadScroll = parameters.readRaw(HIDPropertyKey.trackpadScrollAcceleration)
        let mouseScroll = parameters.readRaw(HIDPropertyKey.mouseScrollAcceleration)
        return "Trackpad: \(describe(trackpad)) · Mouse: \(describe(mouse))" +
            "\nScroll — Trackpad: \(describe(trackpadScroll)) · Mouse: \(describe(mouseScroll))"
    }

    /// Live view of the pointer services Decelerate can shape (diagnostics).
    var serviceSummary: [String] {
        bridge.pointerServices().map { service in
            let representation: String
            if service.hasNativeCurves {
                representation = "parametric curves"
            } else if service.hasAccelerationTable {
                representation = "acceleration table"
            } else {
                representation = "unknown encoding"
            }
            return "\(service.product): \(representation)"
        }
    }
}

/// Tiny helper to run work on the main actor.
private enum OnMain {
    static func run(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
            }
        }
    }
}
