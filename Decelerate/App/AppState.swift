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
            Task { @MainActor in
                self?.refreshDevices()
                self?.refreshStatus()
            }
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

    /// True when Decelerate is shaping the pointer: either an acceleration
    /// amount is below 100%, or a Speed other than 1x still scales the curve.
    /// A non-1x Speed is a real Decelerate override even at 100% acceleration,
    /// so it must not be reported as "Off". Scroll shaping counts too.
    var isEnabled: Bool {
        preferences.values.contains {
            !$0.isNative || abs($0.speedMultiplier - 1.0) >= 0.01 || !$0.isScrollNative
        }
    }

    var connectedDeviceSummary: String {
        if devices.isEmpty { return "No pointing device detected" }
        if devices.count == 1 { return "1 device connected" }
        return "\(devices.count) devices connected"
    }

    var activeSummary: String {
        let categories = PointerClass.allCases.map { preferences(for: $0) }
        // "macOS default acceleration" is only true when Speed is not scaling
        // the macOS curve either, and scroll is untouched too.
        if categories.allSatisfy({ $0.isNative && abs($0.speedMultiplier - 1.0) < 0.01 && $0.isScrollNative }) {
            return "macOS default acceleration"
        }
        let parts: [String] = PointerClass.allCases.map { pointerClass in
            let category = preferences(for: pointerClass)
            let percent = Int((category.accelerationAmount * 100).rounded())
            let speed = category.speedMultiplier
            let speedText = String(format: "%.1f×", speed)
            if category.accelerationAmount <= 0.005 {
                // "1:1" only when Speed does not scale the linear movement;
                // otherwise the card says "linear movement" and this row must
                // not make the 1:1 claim the rest of the UI removed.
                let linearText = abs(speed - 1.0) < 0.01 ? "1:1" : "linear"
                return "\(pointerClass.title) \(linearText) · \(speedText)"
            }
            return "\(pointerClass.title) \(percent)% · \(speedText)"
        }
        let scrollParts: [String] = PointerClass.allCases.compactMap { pointerClass in
            let category = preferences(for: pointerClass)
            guard !category.isScrollNative else { return nil }
            var text = "\(pointerClass.title) scroll"
            if category.scrollAccelerationAmount < 0.995 {
                text += " \(Int((category.scrollAccelerationAmount * 100).rounded()))%"
            }
            if abs(category.scrollSpeedMultiplier - 1.0) >= 0.01 {
                text += String(format: " %.1f×", category.scrollSpeedMultiplier)
            }
            if category.invertScroll {
                text += " inverted"
            }
            return text
        }
        return (parts + scrollParts).joined(separator: " · ")
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

    // MARK: - Scroll preferences

    func setScrollAccelerationAmount(_ amount: Double, for pointerClass: PointerClass) {
        var value = preferences(for: pointerClass)
        let clamped = min(max(amount, 0), 1)
        guard value.scrollAccelerationAmount != clamped else { return }
        value.scrollAccelerationAmount = clamped
        setPreferences(value, for: pointerClass)
    }

    func setScrollSpeedMultiplier(_ speed: Double, for pointerClass: PointerClass) {
        var value = preferences(for: pointerClass)
        let clamped = min(max(speed, SpeedScale.minimumSpeed), SpeedScale.maximumSpeed)
        guard value.scrollSpeedMultiplier != clamped else { return }
        value.scrollSpeedMultiplier = clamped
        setPreferences(value, for: pointerClass)
    }

    func setInvertScroll(_ invert: Bool, for pointerClass: PointerClass) {
        var value = preferences(for: pointerClass)
        guard value.invertScroll != invert else { return }
        value.invertScroll = invert
        setPreferences(value, for: pointerClass)
    }

    // MARK: - Actions

    func refreshDevices() {
        devices = controller.connectedDevices()
    }

    func reapply() {
        controller.apply(preferences)
        refreshStatus()
    }

    /// Pulls the controller's error (if any) back into the observable status.
    /// Retries run after `apply` returns, so the controller calls back here when
    /// a retry series ends, and that is when a deferred failure becomes visible.
    private func refreshStatus() {
        lastError = controller.lastError
        if let error = lastError {
            status = .failed(error)
        } else {
            status = isEnabled ? .active : .idle
        }
    }

    func restoreSystemDefaults() {
        controller.restoreSystemState()
        var updated = preferences
        for pointerClass in PointerClass.allCases {
            updated[pointerClass]?.accelerationAmount = AccelerationController.nativeAcceleration
            // A Speed other than 1x is still a Decelerate curve override, so
            // restoring the system also has to drop it. Otherwise a scaled copy
            // of the macOS curve stays installed after the "restored" state.
            updated[pointerClass]?.speedMultiplier = 1.0
            // Same for scroll: any shaped scroll curve must go so the restore
            // really returns to macOS scrolling.
            updated[pointerClass]?.scrollAccelerationAmount = 1.0
            updated[pointerClass]?.scrollSpeedMultiplier = 1.0
            updated[pointerClass]?.invertScroll = false
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
        defer { isApplyingExternalChanges = false }
        if SMAppService.mainApp.status == .enabled {
            launchAtLogin = true
            store.launchAtLogin = true
            return
        }
        // A bundle that was moved, re-installed or restored from a backup loses
        // its login-item registration while the user's intent is still stored.
        // Silently turning the toggle off would then leave Decelerate not
        // running after the next login, which reads as "deceleration stopped
        // working" with no app around to explain it. Re-register instead, but
        // only from a stable install location so a copy in the build tree never
        // becomes the login item.
        if store.launchAtLogin, Self.isInstalledLocation {
            do {
                try SMAppService.mainApp.register()
                launchAtLogin = true
                store.launchAtLogin = true
                DebugLog.write("launch-at-login: re-registered after the bundle moved")
                return
            } catch {
                DebugLog.write("launch-at-login: re-register failed: \(error.localizedDescription)")
            }
        }
        launchAtLogin = false
        // Keep the stored intent when running from an uninstalled copy; a
        // later install from a stable location should still restore it.
        if Self.isInstalledLocation { store.launchAtLogin = false }
    }

    /// True when the running bundle lives where `Scripts/install.sh` puts it.
    private static var isInstalledLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
