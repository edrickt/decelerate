import Foundation

/// Persistence for Decelerate preferences.
///
/// A tiny `UserDefaults` wrapper: no Core Data, no files, so writes go straight
/// to `UserDefaults` and there is nothing to corrupt. The HID layer is the
/// only thing that touches system-wide state.
struct PreferencesStore {
    private let defaults: UserDefaults
    private enum Key {
        static let trackpad = "pointer.trackpad"
        static let mouse = "pointer.mouse"
        static let launchAtLogin = "general.launchAtLogin"
        static let showDockIcon = "general.showDockIcon"
        static let onboardingDone = "general.onboardingDone"
        static let accelerationOriginals = "system.accelerationOriginals"
        static let accelerationWrites = "system.accelerationWrites"
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

    // MARK: - Snapshot of the user's original HID parameters, so Decelerate can
    // put the Mac back exactly as it was, including after a crash, because the
    // snapshot survives relaunch.

    func saveAccelerationOriginals(_ values: [String: Int32]) {
        encode(values, forKey: Key.accelerationOriginals)
    }

    func loadAccelerationOriginals() -> [String: Int32] {
        decode(Key.accelerationOriginals) ?? [:]
    }

    func clearAccelerationOriginals() {
        defaults.removeObject(forKey: Key.accelerationOriginals)
    }

    /// Values Decelerate last wrote into the HID parameter dictionary. They are
    /// persisted so a crash or relaunch can still tell Decelerate's own output
    /// (for example an index-scaled value) apart from the user's own setting
    /// when rebuilding the snapshot of the original parameters.
    func saveAccelerationWrites(_ values: [String: Int32]) {
        encode(values, forKey: Key.accelerationWrites)
    }

    func loadAccelerationWrites() -> [String: Int32] {
        decode(Key.accelerationWrites) ?? [:]
    }

    func clearAccelerationWrites() {
        defaults.removeObject(forKey: Key.accelerationWrites)
    }

    // MARK: - Helpers

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
