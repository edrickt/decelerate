import Foundation
import SwiftUI

/// The two pointer device classes Decelerate can control.
///
/// macOS keeps separate acceleration parameters for trackpads and mice
/// (`HIDTrackpadAcceleration` / `HIDMouseAcceleration`), so the app exposes one
/// slider per class.
enum PointerClass: String, CaseIterable, Codable, Identifiable, Hashable {
    case trackpad
    case mouse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: return "Trackpad"
        case .mouse: return "Mouse"
        }
    }

    var subtitle: String {
        switch self {
        case .trackpad: return "Built-in and Magic Trackpad"
        case .mouse: return "External and Bluetooth mice"
        }
    }

    var systemImage: String {
        switch self {
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .mouse: return "computermouse.fill"
        }
    }
}

/// Maps the Speed slider's 0…1 position to the multiplier on a logarithmic
/// scale, so 1.0× sits exactly in the middle of the 0.5×–2.0× range.
enum SpeedScale {
    static let minimumSpeed = 0.5
    static let maximumSpeed = 2.0

    static func position(for speed: Double) -> Double {
        let clamped = min(max(speed, minimumSpeed), maximumSpeed)
        return (log2(clamped) + 1.0) / 2.0
    }

    static func speed(for position: Double) -> Double {
        let clamped = min(max(position, 0), 1)
        return pow(2.0, clamped * 2.0 - 1.0)
    }
}

/// User-facing settings for one pointer class.
struct CategoryPreferences: Codable, Equatable, Hashable {
    /// How much of macOS's pointer acceleration to apply.
    ///
    /// 0 = no acceleration at all: a given physical movement always moves the
    /// pointer the same distance (1:1, like Windows with "Enhance pointer
    /// precision" off). 1 = exactly macOS's own acceleration curve. Values in
    /// between blend the two natively inside the HID pipeline.
    var accelerationAmount: Double = 0.5

    /// Pointer speed multiplier for 1:1 movement. macOS's "no acceleration"
    /// passthrough is a geometry-true 1:1 (one device count per 96-dpi point),
    /// which is much slower than an accelerated pointer at ordinary hand speed.
    /// Windows' "Enhance pointer precision off" has a pointer-speed slider; this
    /// is the equivalent. 1.0 = pure physical 1:1.
    var speedMultiplier: Double = 1.0

    var isLinear: Bool { accelerationAmount <= 0.005 }
    var isNative: Bool { accelerationAmount >= 0.995 }

    init(accelerationAmount: Double = 0.5, speedMultiplier: Double = 1.0) {
        self.accelerationAmount = accelerationAmount
        self.speedMultiplier = speedMultiplier
    }

    // MARK: - Codable (with migration from the original on/off setting)

    private enum CodingKeys: String, CodingKey {
        case accelerationAmount
        case speedMultiplier
        case removeAcceleration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let amount = try container.decodeIfPresent(Double.self, forKey: .accelerationAmount) {
            accelerationAmount = amount
        } else if let removed = try container.decodeIfPresent(Bool.self, forKey: .removeAcceleration) {
            // Version 1.0 stored a boolean; true meant "fully linear".
            accelerationAmount = removed ? 0 : 1
        } else {
            accelerationAmount = 0.5
        }
        let decodedSpeed = try container.decodeIfPresent(Double.self, forKey: .speedMultiplier) ?? 1.0
        speedMultiplier = min(max(decodedSpeed, SpeedScale.minimumSpeed), SpeedScale.maximumSpeed)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accelerationAmount, forKey: .accelerationAmount)
        try container.encode(speedMultiplier, forKey: .speedMultiplier)
    }
}
