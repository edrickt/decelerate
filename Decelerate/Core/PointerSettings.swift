import Foundation
import SwiftUI

/// The two pointer device classes Decelerate can control.
///
/// macOS applies its own acceleration curve independently for each class
/// (the built-in trackpad has its own HID service and its own curve), so the
/// app exposes one set of preferences per class.
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

/// User-facing settings for one pointer class.
struct CategoryPreferences: Codable, Equatable, Hashable {
    /// When true, macOS's acceleration curve is replaced with a 1:1 mapping:
    /// a given physical movement always moves the pointer the same number of
    /// points, regardless of speed (Windows "Enhance pointer precision" off).
    var removeAcceleration: Bool = true

    /// Pointer speed multiplier in the linear mapping.
    ///
    /// 0...1 with 0.5 = system default sensitivity. Stored as a unit value so
    /// the UI can present a natural slider while the HID layer maps it to a
    /// device-appropriate multiplier.
    var sensitivity: Double = 0.5

    var speedMultiplier: Double {
        // Exponential mapping keeps the slider perceptually even.
        // 0.5 -> 1.0x, 1.0 -> 4.0x, 0.0 -> 0.25x
        pow(4.0, (sensitivity - 0.5) * 2.0)
    }
}
