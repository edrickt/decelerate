import Foundation

/// Persistence for Decelerate preferences.
///
/// Deliberately a tiny `UserDefaults` wrapper: no Core Data, no files, so the
/// app feels instantaneous and has nothing to corrupt. The HID layer is the
/// only thing that touches system-wide state.
struct PreferencesStore {
    private let defaults: UserDefaults
    private enum Key {
        static let trackpad = "pointer.trackpad"
        static let mouse = "pointer.mouse"
        static let launchAtLogin = "general.launchAtLogin"
        static let showDockIcon = "general.showDockIcon"
        static let onboardingDone = "general.onboardingDone"
        static let originalSystemState = "system.originalState"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [PointerClass: CategoryPreferences] {
        var result: [PointerClass: CategoryPreferences] = [:]
        result[.trackpad] = decode(Key.trackpad) ?? CategoryPreferences()
        result[.mouse] = decode(Key.mouse) ?? CategoryPreferences()
        return result
    }

    func save(_ preferences: [PointerClass: CategoryPreferences]) {
        for (pointerClass, value) in preferences {
            encode(value, forKey: key(for: pointerClass))
        }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        nonmutating set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var showDockIcon: Bool {
        get { defaults.bool(forKey: Key.showDockIcon) }
        nonmutating set { defaults.set(newValue, forKey: Key.showDockIcon) }
    }

    var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }

    // MARK: - Snapshot of the user's original system settings, so Decelerate
    // can restore them when switched off or uninstalled.

    func saveOriginalSystemState(_ state: OriginalSystemState) {
        encode(state, forKey: Key.originalSystemState)
    }

    func loadOriginalSystemState() -> OriginalSystemState? {
        decode(Key.originalSystemState)
    }

    func clearOriginalSystemState() {
        defaults.removeObject(forKey: Key.originalSystemState)
    }

    private func key(for pointerClass: PointerClass) -> String {
        switch pointerClass {
        case .trackpad: return Key.trackpad
        case .mouse: return Key.mouse
        }
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// A snapshot of the acceleration-relevant system state taken the first time
/// Decelerate changes anything, so we can put the Mac back exactly as it was.
struct OriginalSystemState: Codable, Equatable {
    var mouseScaling: Double?
    var trackpadScaling: Double?
    var capturedAt: Date
}
