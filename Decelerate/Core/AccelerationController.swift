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
    /// Values written by this controller (persisted), so its own writes are not
    /// mistaken for external changes or for the user's original setting.
    private var lastWritten: [String: Int32] = [:]
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
        let raw = Int32((number.doubleValue * 65_536.0).rounded())
        return isPlausibleOriginal(raw) ? raw : nil
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
        case HIDPropertyKey.trackpadAcceleration:
            return .trackpad
        case HIDPropertyKey.mouseAcceleration, HIDPropertyKey.pointerAcceleration:
            return .mouse
        default:
            return nil
        }
    }

    private static func fallbackValue(forKey key: String) -> Int32 {
        key == HIDPropertyKey.trackpadAcceleration
            ? HIDPointerParameter.trackpadFallback
            : HIDPointerParameter.mouseFallback
    }

    private static func pointerClass(for service: HIDPointerService) -> PointerClass {
        service.isTrackpad ? .trackpad : .mouse
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
        parameters.startObserving(keys: Self.managedKeys) { [weak self] key, raw in
            OnMain.run { self?.systemParameterChanged(key, raw) }
        }
        // Sleep/wake is the important one: macOS recreates the HID services and
        // the built-in trackpad gets a new registry ID, so both the service
        // enumeration and the applied curves are lost.
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
        suppressExternalChangesUntil = Date().addingTimeInterval(0.75)

        let services = bridge.pointerServices()
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

            // Enumeration is stale (right after wake): leave the parameters
            // alone rather than guessing a representation. Only after every
            // retry with a fresh client has failed -- and only for the mouse
            // class, which is where table-only devices live -- is an unreadable
            // representation accepted as a genuine classic-table device. The
            // trackpad class is always curve-based (built-in and Magic
            // Trackpads), so a trackpad whose curves cannot be read is stale,
            // never a table device, and must never be index-scaled.
            let treatAsTable = pointerClass == .mouse && isFinalRetryAttempt
            if route == .unresolved {
                guard treatAsTable else {
                    needsRetry = true
                    continue
                }
                DebugLog.write("apply: \(pointerClass) curves unreadable, using table scaling")
            }
            let effectiveRoute: Route = route == .unresolved ? .indexScaling : route

            if amount <= Threshold.linear {
                // No acceleration: a constant-gain user curve. User curves take
                // priority over both the parametric curves and the classic
                // table, so this works for every device class.
                if !installConstantCurves(speed: speed, on: classServices) {
                    rejected = true
                    needsRetry = true
                }
                if classServices.isEmpty, retryMissingClasses.contains(pointerClass) {
                    needsRetry = true
                }
                // Curves only take effect while acceleration itself is enabled.
                for key in keys {
                    if !write(key, originalValue(forKey: key)) {
                        rejected = true
                        needsRetry = true
                    }
                }
                continue
            }

            switch effectiveRoute {
            case .curves:
                if amount >= Threshold.native, abs(speed - 1.0) < 0.01 {
                    // Exactly macOS's own curve: hand control back.
                    if !clearOverrides(on: classServices) { rejected = true }
                } else {
                    if !installBlendedCurves(amount, speed: speed, on: classServices) {
                        rejected = true
                        needsRetry = true
                    }
                }
                // Curves only take effect while acceleration itself is enabled.
                for key in keys {
                    if !write(key, originalValue(forKey: key)) {
                        rejected = true
                        needsRetry = true
                    }
                }

            case .indexScaling:
                // Table-only devices (most third-party mice) do not expose
                // parametric curves; amount is the table's own interpolation
                // (scale the acceleration index). Speed cannot be scaled there.
                if !clearOverrides(on: classServices) { rejected = true }
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

            case .absent:
                // No device of this class is attached: hand the parameters
                // back so macOS stays sane without it, and retry when the
                // device is (or should be) present but has no HID service yet.
                if !clearOverrides(on: classServices) { rejected = true }
                for key in keys {
                    if !write(key, originalValue(forKey: key)) {
                        rejected = true
                        needsRetry = true
                    }
                }
                if amount < Threshold.native, retryMissingClasses.contains(pointerClass) {
                    needsRetry = true
                }

            case .unresolved:
                needsRetry = true
            }
        }

        classesWithServices = observedClasses

        persistOriginals()
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
        // Clear the per-service user curves through the event system first; that
        // path does not need the IOHIDSystem parameter connection, so a failed
        // parameter reopen cannot leave the pointer shaped.
        let services = bridge.pointerServices()
        for service in services {
            if !clearOverrides(on: [service]) { rejected = true }
        }
        if parameters.isAvailable {
            for key in Self.managedKeys {
                if !write(key, originalValue(forKey: key)) { rejected = true }
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
            return
        }
        originals.removeAll()
        lastWritten.removeAll()
        persistOriginals()
        persistWrites()
    }

    // MARK: - Routing

    /// Derives the shaping route from the services that are visible right now.
    ///
    /// Parametric curves exist on Apple trackpads (and some Apple mice). Devices
    /// without them use the classic acceleration table, whose interpolation can
    /// be driven by scaling the acceleration index instead. Services with
    /// neither representation are treated as unresolved (stale enumeration);
    /// the caller retries instead of guessing.
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
            guard let curves = service.nativeCurves, !curves.isEmpty else { continue }
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
        let scaled = max(8_192, Int32((Double(base) * amount).rounded()))
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
        if originals.isEmpty {
            store.clearAccelerationOriginals()
        } else {
            store.saveAccelerationOriginals(originals)
        }
    }

    private func persistWrites() {
        if lastWritten.isEmpty {
            store.clearAccelerationWrites()
        } else {
            store.saveAccelerationWrites(lastWritten)
        }
    }

    // MARK: - External changes

    private func systemParameterChanged(_ key: String, _ raw: Int32) {
        guard !isTerminating else { return }
        // Our own writes echo back; ignore them (and anything during the
        // settling window, where macOS may report an equivalent value).
        if lastWritten[key] == raw { return }
        if Date() < suppressExternalChangesUntil { return }
        guard let pointerClass = Self.pointerClass(forParameterKey: key) else { return }
        guard let amount = desired[pointerClass]?.accelerationAmount,
              amount > Threshold.linear, amount < Threshold.native else { return }
        // A genuine external change is a good moment to re-enumerate: wake
        // rewrites can arrive around the same time, and a decision about the
        // shaping route must never be made from a stale event-system client.
        bridge.refresh()
        if Self.isPlausibleOriginal(raw) {
            originals[key] = raw
            persistOriginals()
            // For index-scaled classes, a new base index has to be rescaled.
            if Self.route(for: bridge.pointerServices().filter { Self.pointerClass(for: $0) == pointerClass })
                == .indexScaling {
                _ = writeScaled(key, amount: amount)
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
        return "Trackpad: \(describe(trackpad)) · Mouse: \(describe(mouse))"
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
