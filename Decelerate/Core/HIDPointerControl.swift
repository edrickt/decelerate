import Foundation
import IOKit
import IOKit.hidsystem

/// Pointer-acceleration parameters of the HID system.
///
/// Values are IOFixed (16.16 fixed point). Decelerate reads the user's values
/// and restores them exactly; its own shaping happens through per-service user
/// curves, so it never writes the negative "acceleration disabled" sentinel that
/// `Notes/acceleration-research.md` documents (0% is a constant-gain curve).
enum HIDPointerParameter {
    /// Generic fallback used by devices without a type-specific key.
    static let pointerKey = "HIDPointerAcceleration"

    /// Values to fall back to if the user's original setting cannot be
    /// recovered (e.g. a previous run was killed and no snapshot survived).
    static let trackpadFallback: Int32 = 131_072  // 2.0
    static let mouseFallback: Int32 = 45_056      // 0.6875
}

/// Reads and writes the HID system's system-wide pointer parameters, and
/// observes them for external rewrites.
///
/// The parameter dictionary is the kernel-global `HIDParameters` owned by
/// IOHIDSystem. It is reached through the public (deprecated but exported)
/// IOHIDSystem parameter connection, which needs no root, no TCC permission and
/// no entitlements. Writes take effect immediately for the live acceleration
/// filters and are shared by every pointer device.
///
/// Change notifications come from the full `IOHIDEventSystemClient` (its create
/// and callback-registration entry points are not in the SDK headers, so they
/// are resolved at runtime). That is optional: if it is
/// unavailable the controller still re-applies on wake/attach/launch.
final class HIDPointerControl {
    typealias ChangeCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, CFString?, CFTypeRef?) -> Void

    private typealias CreateClientFn = @convention(c) (CFAllocator?) -> IOHIDEventSystemClient?
    private typealias ScheduleFn = @convention(c) (IOHIDEventSystemClient, DispatchQueue) -> Void
    private typealias UnscheduleFn = @convention(c) (IOHIDEventSystemClient, DispatchQueue) -> Void
    private typealias RegisterPropertyChangedFn = @convention(c) (
        IOHIDEventSystemClient, CFString, ChangeCallback?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let createClient = symbol("IOHIDEventSystemClientCreate", as: CreateClientFn.self)
    private static let schedule = symbol("IOHIDEventSystemClientScheduleWithDispatchQueue", as: ScheduleFn.self)
    private static let unschedule = symbol("IOHIDEventSystemClientUnscheduleFromDispatchQueue", as: UnscheduleFn.self)
    private static let registerPropertyChanged = symbol(
        "IOHIDEventSystemClientRegisterPropertyChangedCallback", as: RegisterPropertyChangedFn.self
    )

    /// IOHIDSystem parameter connection. 0 when unavailable.
    private var handle: io_connect_t = 0
    private var observerClient: IOHIDEventSystemClient?
    private var isObserving = false
    private var changeHandler: ((String, Int32) -> Void)?

    init() {
        observerClient = Self.createClient?(kCFAllocatorDefault)
        openParameterConnection()
    }

    deinit {
        if let observerClient, isObserving, let unschedule = Self.unschedule {
            unschedule(observerClient, DispatchQueue.main)
        }
        if handle != 0 {
            IOServiceClose(handle)
        }
    }

    var isAvailable: Bool { handle != 0 }

    // MARK: - Reading and writing

    func readRaw(_ key: String) -> Int32? {
        guard handle != 0 else {
            openParameterConnection()
            guard handle != 0 else { return nil }
            return readRaw(key)
        }
        var value: Unmanaged<CFTypeRef>?
        guard IOHIDCopyCFTypeParameter(handle, key as CFString, &value) == KERN_SUCCESS,
              let value = value?.takeRetainedValue() else {
            return nil
        }
        return (value as? NSNumber)?.int32Value
    }

    @discardableResult
    func writeRaw(_ key: String, _ raw: Int32) -> Bool {
        guard handle != 0 else {
            openParameterConnection()
            guard handle != 0 else { return false }
            return writeRaw(key, raw)
        }
        return IOHIDSetCFTypeParameter(handle, key as CFString, NSNumber(value: raw)) == KERN_SUCCESS
    }

    /// Re-opens the IOHIDSystem connection (for example after a wake-up where
    /// the connection was torn down).
    @discardableResult
    func reopenIfNeeded() -> Bool {
        if handle != 0, readRaw(HIDPointerParameter.pointerKey) != nil { return true }
        forceReopen()
        return handle != 0
    }

    /// Closes and re-opens the parameter connection unconditionally. Used after
    /// sleep/wake: a connection can survive the sleep in a half-dead state where
    /// reads still succeed but writes never reach the live HID system, so a
    /// liveness probe is not enough.
    @discardableResult
    func forceReopen() -> Bool {
        if handle != 0 {
            IOServiceClose(handle)
            handle = 0
        }
        openParameterConnection()
        return handle != 0
    }

    private func openParameterConnection() {
        let service = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var newHandle: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &newHandle)
        if result == KERN_SUCCESS, newHandle != 0 {
            handle = newHandle
        }
    }

    // MARK: - External change observation

    /// Registers for property-change callbacks so the controller can re-apply
    /// itself when macOS (System Settings, another tool, logout) rewrites a
    /// parameter behind our back.
    func startObserving(keys: [String], onPropertyChanged: @escaping (String, Int32) -> Void) {
        changeHandler = onPropertyChanged
        guard let observerClient, let schedule = Self.schedule, !isObserving else { return }
        schedule(observerClient, DispatchQueue.main)
        isObserving = true
        guard let register = Self.registerPropertyChanged else { return }
        for key in keys {
            register(observerClient, key as CFString, Self.callback,
                     Unmanaged.passUnretained(self).toOpaque(), nil)
        }
    }

    private static let callback: ChangeCallback? = { target, _, property, value in
        guard let target, let property, let value else { return }
        let control = Unmanaged<HIDPointerControl>.fromOpaque(target).takeUnretainedValue()
        let key = property as String
        guard let number = value as? NSNumber else { return }
        control.changeHandler?(key, number.int32Value)
    }
}
