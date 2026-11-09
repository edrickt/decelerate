import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// The app's single observable model. Views own no state; everything they show
/// is derived from here, which keeps the menu bar panel, the settings window
/// and the system HID layer in sync.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case idle
        case active
        case needsPermission
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Off"
            case .active: return "1:1 Pointer"
            case .needsPermission: return "Needs Permission"
            case .failed: return "Error"
            }
        }

        var symbolName: String {
            switch self {
            case .idle: return "cursorarrow"
            case .active: return "cursorarrow.motionlines"
            case .needsPermission: return "exclamationmark.triangle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }

        var isActive: Bool { self == .active }
    }

    // MARK: - Published state

    @Published private(set) var preferences: [PointerClass: CategoryPreferences]
    @Published private(set) var devices: [PointerDevice] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var needsPermission = false
    @Published private(set) var lastError: String?
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isApplyingExternalChanges else { return }
            updateLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var showDockIcon: Bool {
        didSet {
            guard !isApplyingExternalChanges else { return }
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
            store.showDockIcon = showDockIcon
        }
    }

    /// Shown as a transient "Applied" confirmation in the UI.
    @Published private(set) var lastAppliedAt: Date?

    // MARK: - Dependencies

    private let store: PreferencesStore
    private let controller: AccelerationController
    private var isApplyingExternalChanges = false
    private var hasStarted = false

    private init(store: PreferencesStore = PreferencesStore()) {
        self.store = store
        self.controller = .shared
        self.preferences = store.load()
        self.launchAtLogin = store.launchAtLogin
        self.showDockIcon = store.showDockIcon
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)

        controller.startMonitoring { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }

        refreshDevices()
        reapply()
        syncLaunchAtLoginFromSystem()
    }

    /// Called from applicationWillTerminate. System settings are intentionally
    /// left in place (like a real system preference), so relaunching resumes
    /// the same state.
    func shutdown() {
        controller.stopMonitoring()
    }

    // MARK: - Derived

    var isEnabled: Bool {
        preferences.values.contains { $0.removeAcceleration }
    }

    var connectedDeviceSummary: String {
        if devices.isEmpty { return "No pointing devices detected" }
        if devices.count == 1 { return "1 device connected" }
        return "\(devices.count) devices connected"
    }

    var activeSummary: String {
        let enabled = PointerClass.allCases.filter { preferences[$0]?.removeAcceleration == true }
        switch enabled.count {
        case 0: return "Acceleration on, macOS default feel"
        case PointerClass.allCases.count: return "Trackpad and mouse are 1:1"
        default: return "\(enabled[0].title) is 1:1"
        }
    }

    var menuBarSymbol: String {
        preferences[.mouse]?.removeAcceleration == true || preferences[.trackpad]?.removeAcceleration == true
            ? "cursorarrow.motionlines"
            : "cursorarrow"
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Preferences

    func preferences(for pointerClass: PointerClass) -> CategoryPreferences {
        preferences[pointerClass] ?? CategoryPreferences()
    }

    func binding(for pointerClass: PointerClass) -> Binding<CategoryPreferences> {
        Binding(
            get: { self.preferences(for: pointerClass) },
            set: { self.setPreferences($0, for: pointerClass) }
        )
    }

    func setPreferences(_ value: CategoryPreferences, for pointerClass: PointerClass) {
        guard preferences[pointerClass] != value else { return }
        preferences[pointerClass] = value
        store.save([pointerClass: value])
        reapply()
    }

    func setRemoveAcceleration(_ remove: Bool, for pointerClass: PointerClass) {
        var value = preferences(for: pointerClass)
        value.removeAcceleration = remove
        setPreferences(value, for: pointerClass)
    }

    func setSensitivity(_ sensitivity: Double, for pointerClass: PointerClass) {
        var value = preferences(for: pointerClass)
        value.sensitivity = min(max(sensitivity, 0), 1)
        setPreferences(value, for: pointerClass)
    }

    /// Master switch: turns both classes on or off.
    func setEnabled(_ enabled: Bool) {
        var updated = preferences
        for pointerClass in PointerClass.allCases {
            updated[pointerClass]?.removeAcceleration = enabled
        }
        preferences = updated
        store.save(updated)
        reapply()
    }

    // MARK: - Actions

    func refreshDevices() {
        devices = controller.connectedDevices()
        needsPermission = controller.needsPermission
    }

    func reapply() {
        controller.refreshPermissionStatus()
        controller.apply(preferences)
        needsPermission = controller.needsPermission
        lastError = controller.lastError
        switch (isEnabled, needsPermission, lastError) {
        case (false, _, _):
            status = .idle
        case (true, true, _):
            status = .needsPermission
        case (true, false, .some(let error)):
            status = .failed(error)
        case (true, false, nil):
            status = .active
        }
        lastAppliedAt = Date()
    }

    func restoreSystemDefaults() {
        controller.restoreSystemDefaults()
        var updated = preferences
        for pointerClass in PointerClass.allCases {
            updated[pointerClass]?.removeAcceleration = false
        }
        preferences = updated
        store.save(updated)
        reapply()
    }

    func requestPermission() {
        _ = controller.requestPermissionIfNeeded()
        refreshDevices()
        reapply()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Launch at login

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            store.launchAtLogin = enabled
        } catch {
            // Revert the toggle so the UI never lies about the real state.
            isApplyingExternalChanges = true
            launchAtLogin = store.launchAtLogin
            isApplyingExternalChanges = false
            lastError = "Could not update login item: \(error.localizedDescription)"
        }
    }

    private func syncLaunchAtLoginFromSystem() {
        isApplyingExternalChanges = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        store.launchAtLogin = launchAtLogin
        isApplyingExternalChanges = false
    }
}
