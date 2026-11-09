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
        self.originals = store.loadAccelerationOriginals()
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

        let services = bridge.pointerServices()
        var rejected = false
        for pointerClass in PointerClass.allCases {
            let amount = preferences[pointerClass]?.accelerationAmount ?? Self.nativeAcceleration
            let classServices = services.filter { Self.pointerClass(for: $0) == pointerClass }
            let route = Self.route(for: classServices)
            let keys = Self.parameterKeys(for: pointerClass)

            if amount <= Threshold.linear {
                // No acceleration at all: exact raw passthrough.
                if !clearOverrides(on: classServices) { rejected = true }
                for key in keys {
                    if !write(key, HIDPropertyKey.disabledRaw) { rejected = true }
                }
            } else if amount >= Threshold.native {
                // macOS default: remove overrides and restore the parameter.
                if !clearOverrides(on: classServices) { rejected = true }
                for key in keys {
                    if !write(key, originals[key] ?? Self.fallbackValue(forKey: key)) { rejected = true }
                }
            } else {
                switch route {
                case .curves:
                    if !installBlendedCurves(amount, on: classServices) { rejected = true }
                    if !clearOverrides(on: classServices, except: classServices.map(\.registryID)) { rejected = true }
                    for key in keys {
                        if !write(key, originals[key] ?? Self.fallbackValue(forKey: key)) { rejected = true }
                    }
                case .indexScaling:
                    if !clearOverrides(on: classServices) { rejected = true }
                    for key in keys {
                        if !writeScaled(key, amount: amount) { rejected = true }
                    }
                case .none:
                    for key in keys {
                        if !write(key, originals[key] ?? Self.fallbackValue(forKey: key)) { rejected = true }
                    }
                }
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
            if !write(key, originals[key] ?? Self.fallbackValue(forKey: key)) { rejected = true }
        }
        originals.removeAll()
        lastWritten.removeAll()
        persistOriginals()
        lastError = rejected ? "Could not restore the original pointer acceleration." : nil
    }

    func reapply() {
        guard !desired.isEmpty else { return }
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

    private func installBlendedCurves(_ amount: Double, on services: [HIDPointerService]) -> Bool {
        guard !services.isEmpty else { return true }
        var anyInstalled = false
        for service in services {
            guard let curves = service.nativeCurves, !curves.isEmpty else { continue }
            let blended = AccelerationCurveBuilder.blendedCurves(curves, factor: amount)
            if bridge.setCurves(blended, on: service.ref) {
                overriddenServices.insert(service.registryID)
                anyInstalled = true
            }
        }
        return anyInstalled || services.isEmpty
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
        return parameters.writeRaw(key, raw)
    }

    /// Table-based devices: the table interpolates linearly between its identity
    /// entry (acceleration index 0) and its full-acceleration entry, so scaling
    /// the index by the amount is exactly "amount of acceleration".
    private func writeScaled(_ key: String, amount: Double) -> Bool {
        let base = originals[key] ?? Self.fallbackValue(forKey: key)
        let scaled = max(0, Int32((Double(base) * amount).rounded()))
        return write(key, scaled)
    }

    // MARK: - Snapshot

    private func captureOriginalsIfNeeded() {
        var captured = false
        for key in Self.managedKeys {
            guard let raw = parameters.readRaw(key) else { continue }
            guard raw > 0 else { continue }
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
        // Our own writes echo back; ignore them.
        if lastWritten[key] == raw { return }
        guard let pointerClass = Self.pointerClass(forParameterKey: key) else { return }
        guard let amount = desired[pointerClass]?.accelerationAmount,
              amount > Threshold.linear, amount < Threshold.native else { return }
        if raw > 0 {
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
