import Foundation
import SwiftUI

/// The two pointer device classes Decelerate can control.
///
/// macOS keeps separate acceleration parameters for trackpads and mice
/// (`HIDTrackpadAcceleration` / `HIDMouseAcceleration`), so the app exposes one
/// switch per class.
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
    /// When true, macOS's acceleration curve is replaced with a 1:1 mapping: a
    /// given physical movement always moves the pointer the same number of
    /// points, regardless of speed (Windows "Enhance pointer precision" off).
    var removeAcceleration: Bool = true
}
