import Foundation
import IOKit
import IOKit.hidsystem

/// The HID event-system properties Decelerate uses to shape pointer
/// acceleration. Strings are taken from Apple's IOHIDFamily source
/// (`IOHIDPointerScrollFilter.cpp`, `IOHIDEventServiceKeys.h`) and the live
/// WindowServer debug log.
enum HIDPropertyKey {
    /// Trackpad acceleration parameter (`HIDPointerAccelerationType` is this).
    static let trackpadAcceleration = "HIDTrackpadAcceleration"
    /// Mouse acceleration parameter.
    static let mouseAcceleration = "HIDMouseAcceleration"
    /// Generic fallback for devices without a type-specific key.
    static let pointerAcceleration = "HIDPointerAcceleration"
    /// Per-service acceleration type selector.
    static let accelerationType = "HIDPointerAccelerationType"
    /// Per-service parametric acceleration curves (CFArray of CFDictionary).
    static let nativeCurves = "HIDAccelCurves"
    /// Per-service acceleration table (CFData).
    static let accelerationTable = "HIDPointerAccelerationTable"
    /// Overrides which acceleration algorithm the filter builds
    /// (0 = table, 1 = parametric, 2 = default).
    static let algorithm = "HIDPointerAccelerationAlgorithm"
    /// Per-service user-supplied parametric curves. This is the literal key
    /// string the filter looks up (verified from the WindowServer debug log),
    /// despite the Apple constant being named `kIOHIDUserPointerAccelCurvesKey`.
    static let userCurves = "UserPointerAccelCurvesKey"

    static let product = "Product"
    static let transport = "Transport"
    static let builtIn = "BuiltIn"

    static func fixedString(_ raw: Int32) -> String {
        String(format: "%.3f", Double(raw) / 65_536.0)
    }
}

/// Keys inside one parametric acceleration curve dictionary (IOFixed Int32).
enum HIDCurveKey {
    static let index = "HIDAccelIndex"
    static let gainLinear = "HIDAccelGainLinear"
    static let gainParabolic = "HIDAccelGainParabolic"
    static let gainCubic = "HIDAccelGainCubic"
    static let gainQuartic = "HIDAccelGainQuartic"
    static let tangentSpeedLinear = "HIDAccelTangentSpeedLinear"
    static let tangentSpeedParabolicRoot = "HIDAccelTangentSpeedParabolicRoot"
}

/// A pointer-capable service in the HID event system, together with the
/// acceleration representation it natively uses.
struct HIDPointerService {
    let ref: IOHIDServiceClient
    let registryID: UInt64
    let product: String
    /// Value of `HIDPointerAccelerationType` (e.g. "HIDTrackpadAcceleration").
    let accelerationType: String
    /// Native parametric curves, when the device has them (Apple trackpads do).
    let nativeCurves: [[String: Int]]?
    /// Native acceleration table, when the device has one.
    let nativeTable: Data?

    var isTrackpad: Bool {
        accelerationType == HIDPropertyKey.trackpadAcceleration
    }

    /// The device exposes macOS's parametric acceleration curves. Curve-based
    /// devices must be shaped through `UserPointerAccelCurvesKey`, never by
    /// scaling the acceleration index.
    var hasNativeCurves: Bool { nativeCurves != nil }

    /// The device has a readable classic acceleration table.
    var hasAccelerationTable: Bool { nativeTable != nil }
}

/// Access to the pointer event services and their acceleration properties.
///
/// The simple client declared in the SDK is read-only; configuration needs the
/// full `IOHIDEventSystemClient` whose create function is not in the SDK
/// headers, so it is resolved at runtime. `CopyProperty`/`SetProperty` on
/// services are public API.
final class HIDServiceBridge {
    private typealias CreateClientFn = @convention(c) (CFAllocator?) -> IOHIDEventSystemClient?
    private static let createClient: CreateClientFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "IOHIDEventSystemClientCreate") else { return nil }
        return unsafeBitCast(symbol, to: CreateClientFn.self)
    }()

    private let clientFactory: CreateClientFn?
    private var client: IOHIDEventSystemClient?

    init() {
        clientFactory = Self.createClient
        client = clientFactory?(kCFAllocatorDefault)
    }

    var isAvailable: Bool { client != nil }

    /// Re-creates the connection to the HID event system.
    ///
    /// The client is a connection, not a snapshot: macOS tears these down
    /// across sleep/wake and re-creates the device services with new registry
    /// IDs. A client created before sleep keeps returning the old, dead service
    /// objects, whose acceleration representation can no longer be read, so it
    /// must be replaced whenever the environment changes (wake, device attach).
    func refresh() {
        client = clientFactory?(kCFAllocatorDefault)
    }

    // MARK: - Services

    func pointerServices() -> [HIDPointerService] {
        guard let client, let array = IOHIDEventSystemClientCopyServices(client) else { return [] }
        let count = CFArrayGetCount(array)
        var result: [HIDPointerService] = []
        var seen = Set<UInt64>()
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let ref = unsafeBitCast(raw, to: IOHIDServiceClient.self)
            guard isPointer(ref) else { continue }
            let registryID = (IOHIDServiceClientGetRegistryID(ref) as? NSNumber)?.uint64Value ?? 0
            if registryID != 0, !seen.insert(registryID).inserted { continue }
            let product = string(ref, HIDPropertyKey.product) ?? "Pointing Device"
            var accelerationType = string(ref, HIDPropertyKey.accelerationType) ?? ""
            if accelerationType.isEmpty {
                accelerationType = isTrackpadService(ref)
                    ? HIDPropertyKey.trackpadAcceleration
                    : HIDPropertyKey.mouseAcceleration
            }
            result.append(HIDPointerService(
                ref: ref,
                registryID: registryID,
                product: product,
                accelerationType: accelerationType,
                nativeCurves: curves(of: ref),
                nativeTable: table(of: ref)
            ))
        }
        return result
    }

    private func isPointer(_ service: IOHIDServiceClient) -> Bool {
        IOHIDServiceClientConformsTo(service, 0x01, 0x01) != 0   // GD / Pointer
            || IOHIDServiceClientConformsTo(service, 0x01, 0x02) != 0 // GD / Mouse
            || IOHIDServiceClientConformsTo(service, 0x0D, 0x05) != 0 // Digitizer / TouchPad
    }

    private func isTrackpadService(_ service: IOHIDServiceClient) -> Bool {
        if IOHIDServiceClientConformsTo(service, 0x0D, 0x05) != 0 { return true }
        let product = string(service, HIDPropertyKey.product)?.lowercased() ?? ""
        return product.contains("trackpad") || product.contains("touchpad")
    }

    // MARK: - Property access

    func string(_ service: IOHIDServiceClient, _ key: String) -> String? {
        IOHIDServiceClientCopyProperty(service, key as CFString) as? String
    }

    func curves(of service: IOHIDServiceClient) -> [[String: Int]]? {
        guard let raw = IOHIDServiceClientCopyProperty(service, HIDPropertyKey.nativeCurves as CFString)
                as? [[String: Any]], !raw.isEmpty else {
            return nil
        }
        let curves: [[String: Int]] = raw.compactMap { dictionary in
            var result: [String: Int] = [:]
            for (key, value) in dictionary {
                if let number = value as? NSNumber {
                    result[key] = number.intValue
                }
            }
            return result.isEmpty ? nil : result
        }
        return curves.isEmpty ? nil : curves
    }

    func table(of service: IOHIDServiceClient) -> Data? {
        IOHIDServiceClientCopyProperty(service, HIDPropertyKey.accelerationTable as CFString) as? Data
    }

    @discardableResult
    func setCurves(_ curves: [[String: Int]], on service: IOHIDServiceClient) -> Bool {
        let array: [CFDictionary] = curves.map { curve in
            var dictionary: [String: Any] = [:]
            for (key, value) in curve { dictionary[key] = NSNumber(value: value) }
            return dictionary as CFDictionary
        }
        return IOHIDServiceClientSetProperty(service, HIDPropertyKey.userCurves as CFString, array as CFArray)
    }

    // Note: `UserPointerAccelCurvesKey` is write-only from this side. The
    // WindowServer filter reads the value Decelerate sets, but copying the
    // property back (`IOHIDServiceClientCopyProperty`) returns nil even in the
    // writing process, so applied curves cannot be verified by read-back. The
    // `IOHIDServiceClientSetProperty` return value plus the filter's own log
    // (`filterlog.sh`) are the available evidence.

    @discardableResult
    func clearCurves(on service: IOHIDServiceClient) -> Bool {
        // An empty array makes the filter fall back to the device's own curves.
        IOHIDServiceClientSetProperty(service, HIDPropertyKey.userCurves as CFString, [] as CFArray)
    }

    @discardableResult
    func setAlgorithmOverride(_ value: Int32, on service: IOHIDServiceClient) -> Bool {
        IOHIDServiceClientSetProperty(service, HIDPropertyKey.algorithm as CFString, NSNumber(value: value))
    }
}
