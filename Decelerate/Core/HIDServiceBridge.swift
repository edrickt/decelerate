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
    /// Scroll counterpart, verified live the same way: writing it logs
    /// `Acceleration key:UserScrollAccelCurvesKey` and rebuilds the scroll
    /// accelerator, including constant and negative (inverting) gains.
    static let userScrollCurves = "UserScrollAccelCurvesKey"
    /// Per-service parametric scroll curves, when the device has them (Apple
    /// trackpads do; plain USB mice fall back to the filter's default table).
    static let nativeScrollCurves = "HIDScrollAccelCurves"
    /// Per-service scroll acceleration type selector. The scroll filter picks
    /// its acceleration value from this key (not from the pointer type), so
    /// scroll shaping must be routed by it.
    static let scrollAccelerationType = "HIDScrollAccelerationType"
    /// Generic scroll acceleration parameter. Machine-wide: Apple's scroll
    /// filter uses it as the last fallback for every device and the kernel also
    /// links it to the mouse key, so a per-class setting must never shape it.
    static let scrollAcceleration = "HIDScrollAcceleration"
    /// Type-specific scroll acceleration parameters. These are the only scroll
    /// parameters a device class may shape.
    static let mouseScrollAcceleration = "HIDMouseScrollAcceleration"
    static let trackpadScrollAcceleration = "HIDTrackpadScrollAcceleration"

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
    /// Native parametric scroll curves, when the device has them.
    let nativeScrollCurves: [[String: Int]]?
    /// Value of `HIDScrollAccelerationType` (e.g. "HIDMouseScrollAcceleration").
    let scrollAccelerationType: String?
    /// True when the service still has a live IORegistry entry, i.e. it is a
    /// real, settled device and not a dead object from a client created before
    /// sleep. An unreadable acceleration representation on a settled service is
    /// the device's actual encoding; on an unsettled one it means the
    /// enumeration is stale.
    let hasLiveRegistryEntry: Bool

    var isTrackpad: Bool {
        accelerationType == HIDPropertyKey.trackpadAcceleration
    }

    /// The device exposes macOS's parametric acceleration curves. Curve-based
    /// devices must be shaped through `UserPointerAccelCurvesKey`, never by
    /// scaling the acceleration index.
    var hasNativeCurves: Bool { nativeCurves != nil }

    /// The device has a readable classic acceleration table.
    var hasAccelerationTable: Bool { nativeTable != nil }

    /// The device exposes macOS's parametric scroll curves.
    var hasNativeScrollCurves: Bool { nativeScrollCurves != nil }

    /// The parameter key the scroll filter actually reads for this service.
    ///
    /// Apple's lookup order is the type-specific key, then
    /// `HIDMouseScrollAcceleration` for devices without a type, then the
    /// machine-wide `HIDScrollAcceleration`. The generic key is reported as
    /// `nil`: it is shared by every scroll device, so it is never a valid
    /// per-class target. Devices without a type key fall back to the mouse key,
    /// matching what the filter itself does.
    var resolvedScrollParameterKey: String? {
        guard let type = scrollAccelerationType, !type.isEmpty else {
            return HIDPropertyKey.mouseScrollAcceleration
        }
        return type == HIDPropertyKey.scrollAcceleration ? nil : type
    }
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
                nativeTable: table(of: ref),
                nativeScrollCurves: scrollCurves(of: ref),
                scrollAccelerationType: string(ref, HIDPropertyKey.scrollAccelerationType),
                hasLiveRegistryEntry: registryEntryExists(ref)
            ))
        }
        return result
    }

    /// Registry IDs of the pointer services that are live right now.
    ///
    /// A user curve is installed on one `IOHIDServiceClient` and is cached by
    /// that service's filter instance only, so the shaping disappears together
    /// with the service. macOS replaces pointer services without any
    /// notification: the built-in trackpad gets a new one when it wakes from
    /// idle, sleep/wake does it for every device, and WindowServer re-creates
    /// them after a session change. Registry IDs are the cheap, reliable way to
    /// notice that, because they need no property reads and change whenever a
    /// service is replaced.
    ///
    /// This is deliberately separate from `pointerServices()`: it only asks
    /// "which services exist", skipping the per-service property and
    /// IORegistry lookups, so it is cheap enough to poll.
    func pointerServiceFingerprint() -> Set<UInt64> {
        guard let client, let array = IOHIDEventSystemClientCopyServices(client) else { return [] }
        var ids: Set<UInt64> = []
        for index in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let ref = unsafeBitCast(raw, to: IOHIDServiceClient.self)
            guard isPointer(ref) else { continue }
            let id = idOf(ref)
            if id != 0 { ids.insert(id) }
        }
        return ids
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
        if let direct = parseCurves(IOHIDServiceClientCopyProperty(service, HIDPropertyKey.nativeCurves as CFString)) {
            return direct
        }
        // Some services (notably AppleMultitouchDevice) keep their parametric
        // curves in the IORegistry entry but do not expose them through the
        // event-system client. Without this fallback the route stays
        // unresolved forever and blended curves silently never install.
        guard let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { return nil }
        return parseCurves(registryProperty(id.uint64Value, HIDPropertyKey.nativeCurves))
    }

    func table(of service: IOHIDServiceClient) -> Data? {
        if let direct = IOHIDServiceClientCopyProperty(service, HIDPropertyKey.accelerationTable as CFString) as? Data {
            return direct
        }
        return registryProperty(idOf(service), HIDPropertyKey.accelerationTable) as? Data
    }

    func scrollCurves(of service: IOHIDServiceClient) -> [[String: Int]]? {
        if let direct = parseCurves(IOHIDServiceClientCopyProperty(service, HIDPropertyKey.nativeScrollCurves as CFString)) {
            return direct
        }
        guard let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { return nil }
        return parseCurves(registryProperty(id.uint64Value, HIDPropertyKey.nativeScrollCurves))
    }

    private func idOf(_ service: IOHIDServiceClient) -> UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
    }

    /// True when every one of these registry IDs still has a live IORegistry
    /// entry.
    ///
    /// The per-service user curve is cached in the filter instance that belongs
    /// to one service, so "the service object is gone" is exactly "the curve is
    /// gone". The IORegistry is kernel state, so this cannot be fooled by a
    /// stale event-system client, and the lookup costs microseconds where a
    /// fresh `IOHIDEventSystemClientCreate` costs ~100 ms on this machine. It is
    /// therefore the cheap change signal for the applied-state watchdog.
    ///
    /// A terminated service is no longer matched by `IOServiceGetMatchingService`,
    /// and entries that are not `IOService` objects (the registry root, for
    /// example) are reported as absent, which is what the caller wants: only a
    /// live service that can carry a filter instance counts.
    func registryEntriesExist(_ ids: Set<UInt64>) -> Bool {
        for registryID in ids {
            guard registryID != 0, let matching = IORegistryEntryIDMatching(registryID) else { return false }
            let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard entry != 0 else { return false }
            IOObjectRelease(entry)
        }
        return true
    }

    /// True when this service still has a live IORegistry entry. Used to tell a
    /// real device whose acceleration representation genuinely cannot be read
    /// (USB mice: no `HIDAccelCurves` and no table, the filter falls back to its
    /// compiled-in default table) from a dead service object that a client
    /// created before sleep keeps returning.
    func registryEntryExists(_ service: IOHIDServiceClient) -> Bool {
        let id = idOf(service)
        guard id != 0, let matching = IORegistryEntryIDMatching(id) else { return false }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return false }
        IOObjectRelease(entry)
        return true
    }

    /// Read-only lookup of one IORegistry entry property by registry ID.
    private func registryProperty(_ registryID: UInt64, _ key: String) -> Any? {
        guard registryID != 0, let matching = IORegistryEntryIDMatching(registryID) else { return nil }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict[key]
    }

    private func parseCurves(_ value: Any?) -> [[String: Int]]? {
        guard let raw = value as? [[String: Any]], !raw.isEmpty else {
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
    func setScrollCurves(_ curves: [[String: Int]], on service: IOHIDServiceClient) -> Bool {
        let array: [CFDictionary] = curves.map { curve in
            var dictionary: [String: Any] = [:]
            for (key, value) in curve { dictionary[key] = NSNumber(value: value) }
            return dictionary as CFDictionary
        }
        return IOHIDServiceClientSetProperty(service, HIDPropertyKey.userScrollCurves as CFString, array as CFArray)
    }

    // Note: like its pointer counterpart, `UserScrollAccelCurvesKey` is
    // write-only from this side; the filter's own log (`filterlog.sh`) is the
    // available evidence that a write reached the live scroll accelerator.

    @discardableResult
    func clearScrollCurves(on service: IOHIDServiceClient) -> Bool {
        IOHIDServiceClientSetProperty(service, HIDPropertyKey.userScrollCurves as CFString, [] as CFArray)
    }

    @discardableResult
    func setAlgorithmOverride(_ value: Int32, on service: IOHIDServiceClient) -> Bool {
        IOHIDServiceClientSetProperty(service, HIDPropertyKey.algorithm as CFString, NSNumber(value: value))
    }
}
