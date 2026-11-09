import AppKit
import Foundation

/// Owns every interaction with macOS pointer acceleration.
///
/// Mechanism (verified on macOS 26, see `Notes/acceleration-research.md`): the
/// HID system keeps per-class acceleration gains in its system-wide parameter
/// dictionary. A negative IOFixed value makes Apple's `IOHIDPointerScrollFilter`
/// return before installing any acceleration curve, so raw HID deltas pass
/// through unchanged — exact 1:1 movement for the built-in trackpad and for
/// mice. The parameters are reachable through the public IOHIDSystem parameter
/// connection, with no root privileges and no TCC permission, so there is no
/// event tap, no synthetic input, and no added latency.
///
/// Design goals, in order:
///  1. **Native feel** — the change happens inside the HID pipeline itself.
///  2. **Self-healing** — re-applied on wake, on device attach, and whenever
///     macOS rewrites the parameters (System Settings, another tool, logout).
///  3. **Reversible** — originals are snapshotted before the first write and
///     restored exactly when the feature is turned off or the app quits.
@MainActor
final class AccelerationController {
    static let shared = AccelerationController()

    private let control: HIDPointerControl
    private let scanner: HIDDeviceScanner
    private let store: PreferencesStore

    private var desired: [PointerClass: CategoryPreferences] = [:]
    /// Original IOFixed values per parameter key, captured before the first write.
    private var originals: [String: Int32] = [:]
    private var isReapplying = false
    private var wakeObserver: NSObjectProtocol?

    private(set) var lastError: String?
    /// Retained for API stability: this implementation intercepts no input and
    /// therefore never needs a TCC permission.
    private(set) var needsPermission = false

    private init(store: PreferencesStore = PreferencesStore()) {
        self.store = store
        self.control = HIDPointerControl()
        self.scanner = HIDDeviceScanner()
        self.originals = store.loadAccelerationOriginals()
    }

    // MARK: - Mapping

    /// The parameter keys that belong to a pointer class.
    ///
    /// Trackpads always use `HIDTrackpadAcceleration`. Mice use
    /// `HIDMouseAcceleration`, plus the generic `HIDPointerAcceleration` so
    /// third-party pointing devices that rely on the fallback are covered too.
    private static func parameterKeys(for pointerClass: PointerClass) -> [String] {
        switch pointerClass {
        case .trackpad: return [HIDPointerParameter.trackpadKey]
        case .mouse: return [HIDPointerParameter.mouseKey, HIDPointerParameter.pointerKey]
        }
    }

    private static var managedKeys: [String] {
        PointerClass.allCases.flatMap { parameterKeys(for: $0) }
    }

    private static func pointerClass(forParameterKey key: String) -> PointerClass? {
        switch key {
        case HIDPointerParameter.trackpadKey:
            return .trackpad
        case HIDPointerParameter.mouseKey, HIDPointerParameter.pointerKey:
            return .mouse
        default:
            return nil
        }
    }

    private static func fallbackValue(forKey key: String) -> Int32 {
        key == HIDPointerParameter.trackpadKey
            ? HIDPointerParameter.trackpadFallback
            : HIDPointerParameter.mouseFallback
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
        control.startObserving(keys: Self.managedKeys) { [weak self] key, raw in
            OnMain.run { self?.systemParameterChanged(key, raw) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            OnMain.run {
                _ = self?.control.reopenIfNeeded()
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

    /// Applies the desired state and leaves everything already correct alone.
    /// Safe and cheap to call repeatedly; it is the self-healing entry point.
    func apply(_ preferences: [PointerClass: CategoryPreferences]) {
        desired = preferences
        guard control.isAvailable else {
            lastError = "The HID system is unavailable on this Mac."
            return
        }
        captureOriginalsIfNeeded()

        var rejected = false
        for pointerClass in PointerClass.allCases {
            let shouldDisable = preferences[pointerClass]?.removeAcceleration == true
            for key in Self.parameterKeys(for: pointerClass) {
                if shouldDisable {
                    if !control.writeRaw(key, HIDPointerParameter.disabledRaw) { rejected = true }
                } else if let original = originals[key] {
                    // Feature off for this class: hand the parameter back to
                    // macOS and stop tracking it, so a later re-enable captures
                    // whatever tracking speed the user has by then.
                    if !control.writeRaw(key, original) { rejected = true }
                    originals[key] = nil
                }
            }
        }
        persistOriginals()
        lastError = rejected ? "macOS rejected a pointer acceleration setting." : nil
    }

    /// Restores the user's original acceleration values. Used when turning the
    /// feature off and when the app quits, so quitting never leaves the Mac in a
    /// patched state.
    func restoreSystemState() {
        DebugLog.write("restoreSystemState: available=\(control.isAvailable) originals=\(originals)")
        guard control.isAvailable else { return }
        var rejected = false
        for key in Self.managedKeys {
            let value = originals[key] ?? Self.fallbackValue(forKey: key)
            if !control.writeRaw(key, value) { rejected = true }
        }
        DebugLog.write("restoreSystemState: wrote, rejected=\(rejected) values=\(Self.managedKeys.map { "\($0)=\(control.readRaw($0).map(String.init) ?? "nil")" })")
        originals.removeAll()
        persistOriginals()
        lastError = rejected ? "Could not restore the original pointer acceleration." : nil
    }

    func reapply() {
        guard !desired.isEmpty else { return }
        apply(desired)
    }

    private func captureOriginalsIfNeeded() {
        var captured = false
        for key in Self.managedKeys {
            guard let raw = control.readRaw(key) else { continue }
            // Only positive values are real user settings; a negative value is
            // the disabled sentinel (possibly left behind by a previous run).
            guard raw > 0 else { continue }
            // Refresh a stale snapshot (e.g. the user changed tracking speed
            // between launches) but never overwrite it while it is in effect.
            if originals[key] != raw || originals[key] == nil {
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

    /// Called when macOS or another tool rewrites a parameter we manage.
    private func systemParameterChanged(_ key: String, _ raw: Int32) {
        guard let pointerClass = Self.pointerClass(forParameterKey: key) else { return }
        guard desired[pointerClass]?.removeAcceleration == true else { return }
        // Our own write echoes back the sentinel; nothing to do.
        guard raw != HIDPointerParameter.disabledRaw else { return }
        // A real (positive) value means the user changed tracking speed or macOS
        // restored its own setting: adopt it as the new baseline.
        if raw > 0 {
            originals[key] = raw
            persistOriginals()
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
            return raw < 0 ? "1:1 (acceleration off)" : "accelerated (\(HIDPointerParameter.fixedString(raw)))"
        }
        let trackpad = control.readRaw(HIDPointerParameter.trackpadKey)
        let mouse = control.readRaw(HIDPointerParameter.mouseKey)
        return "Trackpad: \(describe(trackpad)) · Mouse: \(describe(mouse))"
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
