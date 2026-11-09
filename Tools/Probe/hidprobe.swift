// hidprobe.swift — Decelerate HID research probe
//
// Enumerates the IOHIDEventSystem services, dumps their properties (event-service
// view + full IORegistry view), reads/writes acceleration-related properties and
// reports TCC/permission state. Build with Tools/Probe/build.sh.
//
// Uses only SDK headers: <IOKit/hidsystem/IOHIDEventSystemClient.h> and
// <IOKit/hidsystem/IOHIDServiceClient.h> are present in the macOS 26 SDK and are
// importable from Swift as `import IOKit.hidsystem`. `IOHIDEventSystemClientCreate`
// (full client, not SimpleClient) is private and resolved with dlsym.

import Foundation
import CoreGraphics
import ApplicationServices
import IOKit.hidsystem
import IOKit.hid

// MARK: - Private symbol: full IOHIDEventSystemClient (admin/monitor client)

typealias IOHIDEventSystemClientCreateFn = @convention(c) (CFAllocator?) -> IOHIDEventSystemClient?
let IOHIDEventSystemClientCreatePtr: IOHIDEventSystemClientCreateFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                          "IOHIDEventSystemClientCreate") else { return nil }
    return unsafeBitCast(sym, to: IOHIDEventSystemClientCreateFn.self)
}()

// MARK: - Helpers

func services(of client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
    guard let arr = IOHIDEventSystemClientCopyServices(client) else { return [] }
    let n = CFArrayGetCount(arr)
    var out: [IOHIDServiceClient] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let raw = CFArrayGetValueAtIndex(arr, i)
        out.append(unsafeBitCast(raw, to: IOHIDServiceClient.self))
    }
    return out
}

func get(_ svc: IOHIDServiceClient, _ key: String) -> AnyObject? {
    IOHIDServiceClientCopyProperty(svc, key as CFString)
}

func getString(_ svc: IOHIDServiceClient, _ key: String) -> String? {
    get(svc, key) as? String
}

func getInt(_ svc: IOHIDServiceClient, _ key: String) -> Int? {
    (get(svc, key) as? NSNumber)?.intValue
}

func getFixed(_ svc: IOHIDServiceClient, _ key: String) -> Double? {
    guard let n = get(svc, key) as? NSNumber else { return nil }
    return n.doubleValue / 65536.0
}

func registryID(_ svc: IOHIDServiceClient) -> UInt64? {
    (IOHIDServiceClientGetRegistryID(svc) as? NSNumber)?.uint64Value
}

enum Kind: String { case trackpad = "trackpad", mouse = "mouse", keyboard = "keyboard", other = "other" }

func kind(_ svc: IOHIDServiceClient) -> Kind {
    // GenericDesktop: Mouse(2), Pointer(1), Keyboard(6)
    if IOHIDServiceClientConformsTo(svc, 0x01, 0x02) != 0 { return .mouse }
    if IOHIDServiceClientConformsTo(svc, 0x01, 0x01) != 0 { return .mouse }
    if IOHIDServiceClientConformsTo(svc, 0x01, 0x06) != 0 { return .keyboard }
    // Digitizer: TouchPad(0x05), TouchScreen(0x04)
    if IOHIDServiceClientConformsTo(svc, 0x0D, 0x05) != 0 { return .trackpad }
    if IOHIDServiceClientConformsTo(svc, 0x0D, 0x04) != 0 { return .trackpad }
    return .other
}

func describe(_ value: AnyObject?) -> String {
    guard let value else { return "nil" }
    if let n = value as? NSNumber {
        // Bool is also NSNumber; show both raw number and fixed-point interpretation.
        let raw = n.int64Value
        let d = n.doubleValue
        return "Number(raw=\(raw), double=\(d), ioFixed=\(d / 65536.0))"
    }
    if let s = value as? String { return "\"\(s)\"" }
    if let data = value as? Data { return "<Data \(data.count) bytes>" }
    if let arr = value as? NSArray { return "(array count=\(arr.count))" }
    if let dict = value as? NSDictionary { return "(dict count=\(dict.count))" }
    return String(describing: value)
}

// Full IORegistry property dump for a service's registry entry.
func dumpRegistryProperties(id: UInt64) {
    guard let matching = IORegistryEntryIDMatching(id) else { return }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { print("    [registry] entry not found"); return }
    defer { IOObjectRelease(service) }

    var className = [CChar](repeating: 0, count: 128)
    IOObjectGetClass(service, &className)
    print("    [registry] class = \(String(cString: className))")

    var props: Unmanaged<CFMutableDictionary>?
    let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
    guard kr == KERN_SUCCESS, let dict = props?.takeRetainedValue() as NSDictionary? else {
        print("    [registry] IORegistryEntryCreateCFProperties failed kr=\(kr)")
        return
    }
    for key in dict.allKeys.map({ "\($0)" }).sorted() {
        print("    [registry] \(key) = \(describe(dict[key] as AnyObject?))")
    }
}

// MARK: - Commands

func cmdList() {
    for (label, client) in clients() {
        print("=== client: \(label) ===")
        for svc in services(of: client) {
            let id = registryID(svc).map { String(format: "0x%llx", $0) } ?? "?"
            let product = getString(svc, "Product") ?? "?"
            let transport = getString(svc, "Transport") ?? "?"
            let accelType = getString(svc, "HIDPointerAccelerationType") ?? "-"
            print("  id=\(id) kind=\(kind(svc).rawValue) product=\"\(product)\" transport=\(transport) accelType=\(accelType)")
        }
    }
}

func clients() -> [(String, IOHIDEventSystemClient)] {
    var out: [(String, IOHIDEventSystemClient)] = []
    out.append(("SimpleClient(public)", IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)))
    if let create = IOHIDEventSystemClientCreatePtr, let c = create(kCFAllocatorDefault) {
        out.append(("FullClient(private dlsym)", c))
    }
    return out
}

let pointerKeys: [String] = [
    "Product", "Transport", "Built-In", "PrimaryUsagePage", "PrimaryUsage",
    "HIDPointerAcceleration", "HIDPointerAccelerationType", "HIDPointerAccelerationTable",
    "HIDMouseAcceleration", "HIDTrackpadAcceleration",
    "HIDUseLinearScalingMouseAcceleration",
    "HIDPointerResolution", "HIDPointerReportRate", "HIDSubinterfaceID",
    "HIDAccelCurves", "HIDScrollAcceleration", "HIDMouseScrollAcceleration",
    "HIDTrackpadScrollAcceleration", "HIDScrollAccelerationTable",
    "DeviceOpenedByEventSystem", "UserPreferences",
]

func cmdDump(pointerOnly: Bool, registry: Bool) {
    for (label, client) in clients() {
        print("=== client: \(label) ===")
        let svcs = services(of: client)
        print("services: \(svcs.count)")
        for svc in svcs {
            let k = kind(svc)
            if pointerOnly && k != .mouse && k != .trackpad { continue }
            let id = registryID(svc) ?? 0
            print("\n-- service id=\(String(format: "0x%llx", id)) kind=\(k.rawValue) product=\"\(getString(svc, "Product") ?? "?")\" --")
            print("   conforms: GD/Mouse=\(IOHIDServiceClientConformsTo(svc, 0x01, 0x02))"
                  + " Digitizer/TouchPad=\(IOHIDServiceClientConformsTo(svc, 0x0D, 0x05))"
                  + " GD/Keyboard=\(IOHIDServiceClientConformsTo(svc, 0x01, 0x06))")
            if registry { dumpRegistryProperties(id: id) }
            for key in pointerKeys {
                print("   prop \(key) = \(describe(get(svc, key)))")
            }
        }
    }
}

func cmdGet(key: String) {
    for (label, client) in clients() {
        print("=== client: \(label) ===")
        for svc in services(of: client) {
            let k = kind(svc)
            guard k == .mouse || k == .trackpad else { continue }
            let id = registryID(svc) ?? 0
            print("  id=\(String(format: "0x%llx", id)) kind=\(k.rawValue) \(key) = \(describe(get(svc, key)))")
        }
    }
}

// value syntax: int:<n> | fixed:<double> | bool:<true|false> | str:<s> | data:<hex>
func makeValue(_ s: String) -> AnyObject? {
    if s.hasPrefix("int:") { return NSNumber(value: Int64(s.dropFirst(4)) ?? 0) }
    if s.hasPrefix("fixed:") {
        let d = Double(s.dropFirst(6)) ?? 0
        return NSNumber(value: Int32(d * 65536.0))
    }
    if s.hasPrefix("bool:") { return NSNumber(value: s.dropFirst(5) == "true") }
    if s.hasPrefix("str:") { return String(s.dropFirst(4)) as NSString }
    if s.hasPrefix("data:") {
        let hex = String(s.dropFirst(5))
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return Data(bytes) as NSData
    }
    if let i = Int64(s) { return NSNumber(value: i) }
    if let d = Double(s) { return NSNumber(value: d) }
    return s as NSString
}

// selector: all | mouse | trackpad | id:<registryID>
func cmdSet(selector: String, key: String, valueString: String) {
    guard let value = makeValue(valueString) else { print("bad value"); return }
    var matched = 0
    for (_, client) in clients() {
        for svc in services(of: client) {
            let k = kind(svc)
            let id = registryID(svc) ?? 0
            let match: Bool
            switch selector {
            case "all": match = true
            case "mouse": match = k == .mouse
            case "trackpad": match = k == .trackpad
            default:
                match = selector.hasPrefix("id:") && UInt64(selector.dropFirst(3)) == id
            }
            if !match { continue }
            matched += 1
            let before = describe(get(svc, key))
            let ok = IOHIDServiceClientSetProperty(svc, key as CFString, value)
            let after = describe(get(svc, key))
            print("id=\(String(format: "0x%llx", id)) kind=\(k.rawValue) product=\"\(getString(svc, "Product") ?? "?")\"")
            print("   set \(key)=\(valueString) -> returned \(ok)")
            print("   before=\(before)")
            print("   after =\(after)")
        }
    }
    print("services matched: \(matched)")
}

func cmdAccess() {
    print("AXIsProcessTrusted() = \(AXIsProcessTrusted())")
    print("AXIsProcessTrustedWithOptions(prompt=false) = \(AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary))")
    print("CGPreflightListenEventAccess() = \(CGPreflightListenEventAccess())")
    print("CGPreflightPostEventAccess() = \(CGPreflightPostEventAccess())")
    print("IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) = \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) (0=granted,1=denied,2=unknown)")
    print("IOHIDCheckAccess(kIOHIDRequestTypePostEvent) = \(IOHIDCheckAccess(kIOHIDRequestTypePostEvent).rawValue)")

    let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
    let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                userInfo: nil)
    print("CGEventTapCreate(.cghidEventTap, .listenOnly, mouseMoved) = \(tap != nil ? "OK" : "NIL (no TCC)")")
    if let tap { CFMachPortInvalidate(tap) }
}

func usage() {
    print("""
    usage: hidprobe <command> [args]
      list
      dump [--pointer-only] [--no-registry]
      get <key>
      set <all|mouse|trackpad|id:0x...> <key> <value>   value: int:N | fixed:D | bool:true | str:S | data:hex
      access
    """)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(1) }
switch args[1] {
case "list": cmdList()
case "dump":
    let pointerOnly = args.contains("--pointer-only")
    let registry = !args.contains("--no-registry")
    cmdDump(pointerOnly: pointerOnly, registry: registry)
case "get":
    guard args.count >= 3 else { usage(); exit(1) }
    cmdGet(key: args[2])
case "set":
    guard args.count >= 5 else { usage(); exit(1) }
    cmdSet(selector: args[2], key: args[3], valueString: args[4])
case "access": cmdAccess()
default: usage(); exit(1)
}
