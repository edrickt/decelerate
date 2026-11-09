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
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Off"
            case .active: return "1:1 Pointer"
            case .failed: return "Error"
            }
        }

        var symbolName: String {
            switch self {
            case .idle: return "cursorarrow"
            case .active: return "cursorarrow.motionlines"
            case .failed: return "xmark.octagon.fill"
            }
        }

        var isActive: Bool { self == .active }
    }

    // MARK: - Published state

    @Published private(set) var preferences: [PointerClass: CategoryPreferences]
    @Published private(set) var devices: [PointerDevice] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastAppliedAt: Date?
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

    /// Called from applicationWillTerminate: hands the pointer acceleration back
    /// to macOS exactly as it was before Decelerate, so quitting the app never
    /// leaves the system in a patched state. The user's switches are kept for
    /// the next launch.
    func prepareForTermination() {
        DebugLog.write("prepareForTermination: restoring")
        controller.prepareForTermination()
        DebugLog.write("prepareForTermination: restored, error=\(controller.lastError ?? "none")")
    }

    // MARK: - Derived

    var isEnabled: Bool {
        preferences.values.contains { !$0.isNative }
    }

    var connectedDeviceSummary: String {
        if devices.isEmpty { return "No pointing device detected" }
        if devices.count == 1 { return "1 device connected" }
        return "\(devices.count) devices connected"
    }

    var activeSummary: String {
        let values = PointerClass.allCases.map { preferences(for: $0).accelerationAmount }
        if values.allSatisfy({ $0 >= 0.995 }) { return "macOS default acceleration" }
        let parts: [String] = PointerClass.allCases.map { pointerClass in
            let category = preferences(for: pointerClass)
            let percent = Int((category.accelerationAmount * 100).rounded())
            let speed = category.speedMultiplier
            let speedText = String(format: "%.1f×", speed)
            if category.accelerationAmount <= 0.005 {
                return "\(pointerClass.title) 1:1 · \(speedText)"
            }
            return "\(pointerClass.title) \(percent)% · \(speedText)"
        }
        return parts.joined(separator: " · ")
    }

    var menuBarSymbol: String {
        isEnabled ? "cursorarrow.motionlines" : "cursorarrow"
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Live description of the system parameters, e.g. for the General tab.
    var systemParameterSummary: String {
        controller.parameterSummary
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

    func setSpeedMultiplier(_ speed: Double, for pointerClass: PointerClass) {
        var value = preferences(for: pointerClass)
        let clamped = min(max(speed, SpeedScale.minimumSpeed), SpeedScale.maximumSpeed)
        guard value.speedMultiplier != clamped else { return }
        value.speedMultiplier = clamped
        setPreferences(value, for: pointerClass)
    }

    func setAccelerationAmount(_ amount: Double, for pointerClass: PointerClass) {
        var value = preferences(for: pointerClass)
        let clamped = min(max(amount, 0), 1)
        guard value.accelerationAmount != clamped else { return }
        value.accelerationAmount = clamped
        setPreferences(value, for: pointerClass)
    }

    /// Sets every pointer class to the same acceleration amount.
    func setAccelerationAmountForAll(_ amount: Double) {
        var updated = preferences
        let clamped = min(max(amount, 0), 1)
        for pointerClass in PointerClass.allCases {
            updated[pointerClass]?.accelerationAmount = clamped
        }
        guard updated != preferences else { return }
        preferences = updated
        store.save(updated)
        reapply()
    }

    // MARK: - Actions

    func refreshDevices() {
        devices = controller.connectedDevices()
    }

    func reapply() {
        controller.apply(preferences)
        lastError = controller.lastError
        if let error = lastError {
            status = .failed(error)
        } else {
            status = isEnabled ? .active : .idle
        }
        lastAppliedAt = Date()
    }

    func restoreSystemDefaults() {
        controller.restoreSystemState()
        var updated = preferences
        for pointerClass in PointerClass.allCases {
            updated[pointerClass]?.accelerationAmount = AccelerationController.nativeAcceleration
        }
        preferences = updated
        store.save(updated)
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
