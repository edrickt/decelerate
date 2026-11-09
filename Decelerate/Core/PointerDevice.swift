import Foundation

/// A pointing device as reported by the HID system.
///
/// Both the built-in trackpad and every connected mouse appear here. The UI
/// uses this list for diagnostics ("2 devices detected") and the settings
/// window's device tab; the actual acceleration control is per *class*.
struct PointerDevice: Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case trackpad
        case mouse
        case unknown

        var pointerClass: PointerClass? {
            switch self {
            case .trackpad: return .trackpad
            case .mouse: return .mouse
            case .unknown: return nil
            }
        }
    }

    /// IOHID service registry ID. Stable for the lifetime of the connection.
    let id: UInt64
    let name: String
    let vendorID: Int
    let productID: Int
    let kind: Kind
    let isBuiltIn: Bool

    var pointerClass: PointerClass { kind.pointerClass ?? .mouse }

    var isInternal: Bool { isBuiltIn }
}
