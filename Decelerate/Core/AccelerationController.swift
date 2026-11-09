import AppKit
import Foundation

/// Owns every interaction with macOS pointer acceleration.
///
/// Mechanism (verified on macOS 26, see `Notes/acceleration-research.md`):
/// pointer acceleration is applied by Apple's `IOHIDPointerScrollFilter` from
/// system-wide parameters. A negative IOFixed value disables acceleration
/// entirely (raw deltas pass through = exact 1:1). For intermediate amounts
/// Decelerate feeds the filter a *blended acceleration curve* per pointer
/// service: the device's own macOS curve interpolated toward the identity line.
/// The filter caches those user curves per service and rebuilds its accelerator
/// from them. Nothing is intercepted, no TCC permission is needed and no
/// latency is added.
///
/// Devices that only have a classic acceleration *table* (most third-party
/// mice) use the table's own linear interpolation between "identity" and
/// "full acceleration": scaling the acceleration index by the chosen amount is
/// exactly that blend, so no table rewriting is needed.
///
/// Design goals, in order:
///  1. **Native feel** — everything happens inside the HID pipeline.
///  2. **Self-healing** — re-applied on wake, on device attach, and whenever
///     macOS rewrites the parameters.
///  3. **Reversible** — originals are snapshotted and restored exactly.
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

    private enum Route {
        case curves
        case indexScaling
        case none
    }

    private let parameters: HIDPointerControl
    private let bridge: HIDServiceBridge
    private let scanner: HIDDeviceScanner
    private let store: PreferencesStore

    private var desired: [PointerClass: CategoryPreferences] = [:]
    /// Original IOFixed acceleration values per parameter key.
    private var originals: [String: Int32] = [:]
    /// Services that currently carry a Decelerate curve override.
    private var overriddenServices: Set<UInt64> = []
    /// Values written by this controller, so its own writes are not mistaken
    /// for external changes.
    private var lastWritten: [String: Int32] = [:]
    private var isReapplying = false
    private var isTerminating = false
    /// While a re-apply is writing parameters, property-change callbacks are
    /// echoes of our own writes and must not be mistaken for user changes.
    private var suppressExternalChangesUntil = Date.distantPast
    private var wakeObserver: NSObjectProtocol?

    private(set) var lastError: String?
    /// Retained for API stability: this implementation intercepts no input and
    /// therefore never needs a TCC permission.
    private(set) var needsPermission = false

    private init(store: PreferencesStore = PreferencesStore()) {
        self.store = store
        self.parameters = HIDPointerControl()
        self.bridge = HIDServiceBridge()
        self.scanner = HIDDeviceScanner()
        // Snapshots written by older/buggy builds can be corrupt (a valid
        // acceleration value is a curve selector in a known range; a stray
        // value like 1 selects the identity curve and makes the pointer feel
        // permanently slow). Validate every entry and derive a sane fallback
        // from the user's own macOS tracking-speed setting.
        var loaded = store.loadAccelerationOriginals()
        for key in Self.managedKeys {
            if let raw = loaded[key], Self.isPlausibleOriginal(raw) {
                continue
            }
            loaded[key] = Self.trackingSpeedRaw(forKey: key)
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

    /// Derives the acceleration value matching the user's macOS tracking-speed
    /// slider, so "100%" really is their normal macOS feel even if our snapshot
    /// is missing or was corrupted.
    private static func trackingSpeedRaw(forKey key: String) -> Int32 {
        let defaultsKey = key == HIDPropertyKey.trackpadAcceleration
            ? "com.apple.trackpad.scaling"
            : "com.apple.mouse.scaling"
        if let number = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber {
            let raw = Int32((number.doubleValue * 65_536.0).rounded())
            if isPlausibleOriginal(raw) { return raw }
        }
        return key == HIDPropertyKey.trackpadAcceleration
            ? HIDPropertyKey.trackpadFallback
            : HIDPropertyKey.mouseFallback
    }

    /// The value to hand back to macOS for a key, guaranteed to be sane.
    private func originalValue(forKey key: String) -> Int32 {
        if let raw = originals[key], Self.isPlausibleOriginal(raw) { return raw }
        let derived = Self.trackingSpeedRaw(forKey: key)
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
            ? HIDPropertyKey.trackpadFallback
            : HIDPropertyKey.mouseFallback
    }

    private static func pointerClass(for service: HIDPointerService) -> PointerClass {
        service.isTrackpad ? .trackpad : .mouse
    }

    // MARK: - Devices

    func connectedDevices() -> [PointerDevice] {
        scanner.devices()
    }

    func startMonitoring(onChange: @escaping () -> Void) {
        scanner.startMonitoring { [weak self] in
            OnMain.run {
                onChange()
                self?.reapply()
            }
        }
        parameters.startObserving(keys: Self.managedKeys) { [weak self] key, raw in
            OnMain.run { self?.systemParameterChanged(key, raw) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            OnMain.run {
                _ = self?.parameters.reopenIfNeeded()
                self?.reapply()
            }
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
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Apply

    /// Applies the desired acceleration amount for both pointer classes.
    /// Safe and cheap to call repeatedly; it is the self-healing entry point.
    func apply(_ preferences: [PointerClass: CategoryPreferences]) {
        desired = preferences
        guard parameters.isAvailable else {
            lastError = "The HID system is unavailable on this Mac."
            return
        }
        captureOriginalsIfNeeded()
        suppressExternalChangesUntil = Date().addingTimeInterval(0.75)

        let services = bridge.pointerServices()
        var rejected = false
        for pointerClass in PointerClass.allCases {
            let category = preferences[pointerClass] ?? CategoryPreferences()
            let amount = category.accelerationAmount
            let speed = category.speedMultiplier
            let classServices = services.filter { Self.pointerClass(for: $0) == pointerClass }
            let route = Self.route(for: classServices)
            let keys = Self.parameterKeys(for: pointerClass)

            if amount <= Threshold.linear {
                // No acceleration: a constant-gain curve. Gain 1.0 is the
                // physical 1:1 identity, so the speed multiplier is what makes
                // 1:1 usable at ordinary hand speed (Windows has the same
                // pointer-speed slider with "enhance pointer precision" off).
                if !installConstantCurves(speed: speed, on: classServices) { rejected = true }
            } else if route == .curves {
                if amount >= Threshold.native, abs(speed - 1.0) < 0.01 {
                    // Exactly macOS's own curve: hand control back.
                    if !clearOverrides(on: classServices) { rejected = true }
                } else {
                    if !installBlendedCurves(amount, speed: speed, on: classServices) { rejected = true }
                    if !clearOverrides(on: classServices, except: classServices.map(\.registryID)) { rejected = true }
                }
            } else if route == .indexScaling {
                // Table-only devices (most third-party mice) do not expose
                // parametric curves; amount is the table's own interpolation
                // (scale the acceleration index). Speed cannot be scaled there.
                if !clearOverrides(on: classServices) { rejected = true }
                if amount >= Threshold.native {
                    for key in keys { if !write(key, originalValue(forKey: key)) { rejected = true } }
                    continue
                }
                for key in keys { if !writeScaled(key, amount: amount) { rejected = true } }
                continue
            } else {
                // No device of this class is attached: hand the parameters back.
                if !clearOverrides(on: classServices) { rejected = true }
                for key in keys { if !write(key, originalValue(forKey: key)) { rejected = true } }
                continue
            }
            // Curves only take effect while acceleration itself is enabled.
            for key in keys {
                if !write(key, originalValue(forKey: key)) { rejected = true }
            }
        }
        persistOriginals()
        lastError = rejected ? "macOS rejected a pointer acceleration setting." : nil
    }

    /// Restores the user's original acceleration. Used when turning the feature
    /// off and when the app quits, so quitting never leaves the Mac patched.
    func restoreSystemState() {
        guard parameters.isAvailable else { return }
        let services = bridge.pointerServices()
        overriddenServices.formUnion(services.map(\.registryID))
        var rejected = false
        for service in services {
            if !clearOverrides(on: [service]) { rejected = true }
        }
        overriddenServices.removeAll()
        for key in Self.managedKeys {
            if !write(key, originalValue(forKey: key)) { rejected = true }
        }
        originals.removeAll()
        lastWritten.removeAll()
        persistOriginals()
        lastError = rejected ? "Could not restore the original pointer acceleration." : nil
    }

    func reapply() {
        guard !desired.isEmpty, !isTerminating else { return }
        apply(desired)
    }

    // MARK: - Routing

    /// Parametric curves exist on Apple trackpads (and some Apple mice). Devices
    /// without them use the classic acceleration table, whose interpolation can
    /// be driven by scaling the acceleration index instead.
    private static func route(for services: [HIDPointerService]) -> Route {
        if services.isEmpty { return .none }
        return services.allSatisfy({ $0.nativeCurves != nil }) ? .curves : .indexScaling
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
            if bridge.setCurves(blended, on: service.ref) {
                overriddenServices.insert(service.registryID)
            } else {
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
            if bridge.setCurves(constant, on: service.ref) {
                overriddenServices.insert(service.registryID)
            } else {
                ok = false
            }
        }
        return ok
    }

    /// Removes Decelerate's curve overrides, optionally keeping some services.
    private func clearOverrides(on services: [HIDPointerService], except keep: [UInt64] = []) -> Bool {
        guard !services.isEmpty else { return true }
        var ok = true
        let keepSet = Set(keep)
        for service in services
        where overriddenServices.contains(service.registryID) && !keepSet.contains(service.registryID) {
            if !bridge.clearCurves(on: service.ref) { ok = false }
            if !bridge.setAlgorithmOverride(AlgorithmOverride.native, on: service.ref) { ok = false }
            overriddenServices.remove(service.registryID)
        }
        return ok
    }

    // MARK: - Parameters

    @discardableResult
    private func write(_ key: String, _ raw: Int32) -> Bool {
        lastWritten[key] = raw
        // Avoid churning the HID pipeline when the value is already correct;
        // curve changes trigger their own rebuild.
        if parameters.readRaw(key) == raw { return true }
        return parameters.writeRaw(key, raw)
    }

    /// Table-based devices: the table interpolates linearly between its identity
    /// entry (acceleration index 0) and its full-acceleration entry, so scaling
    /// the index by the amount is exactly "amount of acceleration".
    private func writeScaled(_ key: String, amount: Double) -> Bool {
        let base = originalValue(forKey: key)
        let scaled = max(8_192, Int32((Double(base) * amount).rounded()))
        return write(key, scaled)
    }

    // MARK: - Snapshot

    private func captureOriginalsIfNeeded() {
        var captured = false
        for key in Self.managedKeys {
            guard let raw = parameters.readRaw(key), Self.isPlausibleOriginal(raw) else { continue }
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
            let representation = service.nativeCurves != nil ? "parametric curves" : "acceleration table"
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
