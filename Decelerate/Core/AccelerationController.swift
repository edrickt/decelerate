import Foundation
import AppKit
import IOKit.hid

/// Owns every interaction with the system HID stack.
///
/// Design goals, in order:
///  1. **Native feel** — 1:1 movement must come from the HID layer itself, not
///     from rewritten synthetic mouse events. No event tap, no added latency,
///     no lost events, no interference with drags, gestures or clicks.
///  2. **Self-healing** — HID services are recreated on sleep/wake, on
///     reconnect and on log-in, so the controller re-applies state whenever
///     anything changes (`IOHIDManager` match notifications + workspace
///     notifications). 
///  3. **Reversible** — the user's original acceleration settings are
///     snapshotted before the first change and can be restored exactly.
///
/// NOTE: This file is filled in by the HID core work. The interface below is
/// the contract the UI layer depends on; do not change it without telling the
/// UI owner.
@MainActor
final class AccelerationController {
    static let shared = AccelerationController()

    enum Failure: LocalizedError {
        case deviceUnavailable
        case systemRejected(String)

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable:
                return "No pointing device was found."
            case .systemRejected(let reason):
                return reason
            }
        }
    }

    private let store: PreferencesStore
    private var eventTap: AnyObject?

    private(set) var originalSystemState: OriginalSystemState?
    private(set) var lastError: String?

    /// True when the fallback path (event tap) is required and not yet
    /// authorized by the user in System Settings → Privacy & Security.
    private(set) var needsPermission = false

    private init(store: PreferencesStore = PreferencesStore()) {
        self.store = store
        self.originalSystemState = store.loadOriginalSystemState()
    }

    // MARK: - Devices

    /// Pointing devices currently attached. Implemented by the HID core.
    func connectedDevices() -> [PointerDevice] {
        []
    }

    /// Begins observing attach/detach and wake notifications.
    func startMonitoring(onChange: @escaping () -> Void) {
        _ = onChange
    }

    func stopMonitoring() {}

    // MARK: - State

    /// Applies the desired state for both pointer classes.
    func apply(_ preferences: [PointerClass: CategoryPreferences]) {
        _ = preferences
    }

    /// Puts the Mac's pointer acceleration back exactly as it was found.
    func restoreSystemDefaults() {
        store.clearOriginalSystemState()
    }

    // MARK: - Permissions

    /// Requests the TCC permission used by the fallback path, if any.
    func requestPermissionIfNeeded() -> Bool {
        true
    }

    func refreshPermissionStatus() {
        needsPermission = false
    }
}
