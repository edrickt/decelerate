import Foundation
import IOKit
import IOKit.hid

/// Enumerates pointing devices through the public HID manager API.
///
/// This is only used to *describe* hardware in the UI (and to notice
/// attach/detach). Acceleration is configured through `HIDEventSystem`,
/// which talks to the event services that actually apply the curves.
final class HIDDeviceScanner {
    private let manager: IOHIDManager
    private var addedCallback: (() -> Void)?
    private var removedCallback: (() -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchings: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02], // mouse
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x01], // pointer
            [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x05], // touchpad
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchings as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let scanner = Unmanaged<HIDDeviceScanner>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { scanner.addedCallback?() }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let scanner = Unmanaged<HIDDeviceScanner>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { scanner.removedCallback?() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func startMonitoring(onChange: @escaping () -> Void) {
        addedCallback = onChange
        removedCallback = onChange
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func stopMonitoring() {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        addedCallback = nil
        removedCallback = nil
    }

    func devices() -> [PointerDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        var seen = Set<UInt64>()
        var result: [PointerDevice] = []
        for device in set {
            guard let service = IOHIDDeviceGetService(device) as io_service_t?, service != 0 else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            guard !seen.contains(entryID) else { continue }
            seen.insert(entryID)

            let product = property(device, kIOHIDProductKey) as? String ?? "Unknown Device"
            let transport = property(device, kIOHIDTransportKey) as? String ?? ""
            let vendor = (property(device, kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0
            let productID = (property(device, kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0
            let builtIn = (property(device, kIOHIDBuiltInKey) as? NSNumber)?.boolValue
                ?? (transport == "SPI" || transport == "FIFO")

            result.append(PointerDevice(
                id: entryID,
                name: product,
                vendorID: vendor,
                productID: productID,
                kind: Self.classify(product: product, transport: transport, isBuiltIn: builtIn),
                isBuiltIn: builtIn
            ))
        }
        // Trackpads first (they are the built-in device), then mice, stable by name.
        return result.sorted {
            if $0.kind != $1.kind { return $0.kind == .trackpad }
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    private static func classify(product: String, transport: String, isBuiltIn: Bool) -> PointerDevice.Kind {
        let lowered = product.lowercased()
        if lowered.contains("trackpad") || lowered.contains("touchpad") { return .trackpad }
        if isBuiltIn && (transport == "SPI" || transport == "FIFO") { return .trackpad }
        return .mouse
    }
}
