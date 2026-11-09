// PointerAccelerationController.swift
// Decelerate — drop-in pointer-acceleration override for macOS 13+/26.
// Verified on macOS 26.0.1 (build 25A362), Apple M-series.
//
// Mechanism: IOHIDSystem's kernel-global parameter dictionary. Writing a NEGATIVE
// IOFixed value to "HIDTrackpadAcceleration" / "HIDMouseAcceleration" makes
// IOHIDPointerScrollFilter install no acceleration curve at all, so raw HID deltas
// pass through unchanged -> exact 1:1 linear pointer movement, for the built-in
// trackpad and for mice. This is the macOS equivalent of turning OFF
// "Enhance pointer precision" in Windows.
//
// API: IOHIDParamConnectType (public, deprecated but exported):
//   IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
//   IOServiceOpen(service, mach_task_self_, kIOHIDParamConnectType, &handle)
//   IOHIDCopyCFTypeParameter(handle, key, &out)   // read current value (for restore)
//   IOHIDSetCFTypeParameter(handle, key, value)   // write raw IOFixed value
//
// Requires NO root, NO TCC permission, NO entitlements; works from an ad-hoc signed,
// non-sandboxed local build (verified with an app whose AXIsProcessTrusted()==false).
//
// Values are IOFixed 16.16: raw = round(value * 65536).
//   disable  -> raw -65536  (IOFixed -1.0, the documented "acceleration disabled" sentinel)
//   restore  -> the exact raw value read at launch (e.g. 131072 == 2.0)
//
// HIDUseLinearScalingMouseAcceleration=1 is a different thing: Apple only honors it
// when a service's HIDPointerAccelerationType == "HIDMouseAcceleration" (mice), so it
// does NOT linearize the built-in trackpad. Decelerate uses negative values instead.
//
// Values live in kernel state: they survive this app quitting, but not logout/reboot.
// Changing System Settings "Tracking speed" rewrites positive values, so call
// reapplyLinearMovement() on wake, on device arrival, and after mouse/trackpad prefs change.
//
// See Notes/acceleration-research.md for the full evidence trail.

import Foundation
import IOKit
import IOKit.hidsystem

final class PointerAccelerationController {

    enum Key: String {
        case trackpad = "HIDTrackpadAcceleration"
        case mouse = "HIDMouseAcceleration"
        case pointer = "HIDPointerAcceleration"
        case linearMouse = "HIDUseLinearScalingMouseAcceleration"
        case scroll = "HIDScrollAcceleration"   // never touched by Decelerate

        static let pointerKeys: [Key] = [.trackpad, .mouse, .pointer]
    }

    /// IOFixed(1.0) raw value (16.16 fixed point).
    static let iofixedOne: Int32 = 65536
    /// Raw IOFixed representation of -1.0: the "acceleration disabled" sentinel.
    static let disabledRaw: Int32 = -65536

    private let handle: io_connect_t
    private var snapshot: [Key: Int32] = [:]
    private(set) var isLinear = false

    /// Opens the IOHIDSystem parameter connection. Fails only on unusual systems.
    init?() {
        let service = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var handle: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &handle) == KERN_SUCCESS,
              handle != 0 else { return nil }
        self.handle = handle
    }

    deinit {
        IOServiceClose(handle)
    }

    // MARK: - Raw parameter access

    /// Reads the current kernel-global value as a raw IOFixed Int32, or nil if absent.
    func rawValue(for key: Key) -> Int32? {
        var out: Unmanaged<CFTypeRef>?
        guard IOHIDCopyCFTypeParameter(handle, key.rawValue as CFString, &out) == KERN_SUCCESS,
              let value = out?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.int32Value
    }

    /// Writes a raw IOFixed Int32 into the kernel-global parameter dictionary.
    @discardableResult
    func setRaw(_ raw: Int32, for key: Key) -> Bool {
        IOHIDSetCFTypeParameter(handle, key.rawValue as CFString, NSNumber(value: raw)) == KERN_SUCCESS
    }

    /// Writes a *speed* value (IOFixed conversion done by IOKit). MUST be >= 0;
    /// IOKit clamps negative values to 0 (verified), so this cannot disable acceleration.
    @discardableResult
    func setAccelerationSpeed(_ value: Double, for key: Key) -> Bool {
        IOHIDSetAccelerationWithKey(handle, key.rawValue as CFString, value) == KERN_SUCCESS
    }

    // MARK: - Public API

    /// Disable pointer acceleration on the built-in trackpad and all mice, remembering
    /// the previous values for `restoreSystemAcceleration()`.
    @discardableResult
    func enableLinearMovement() -> Bool {
        if !isLinear {
            // Refuse to snapshot a disabled sentinel (e.g. previous run crashed while on).
            for key in Key.pointerKeys {
                if let raw = rawValue(for: key), raw >= 0 { snapshot[key] = raw }
            }
        }
        var ok = false
        for key in Key.pointerKeys {
            ok = setRaw(Self.disabledRaw, for: key) || ok
        }
        isLinear = ok
        return ok
    }

    /// Restore the values captured by the most recent `enableLinearMovement()`.
    func restoreSystemAcceleration() {
        for (key, raw) in snapshot {
            setRaw(raw, for: key)
        }
        snapshot.removeAll()
        isLinear = false
    }

    /// Re-assert linear mode after some other process (System Settings, login items,
    /// wake re-initialisation) rewrote the parameters.
    @discardableResult
    func reapplyLinearMovement() -> Bool {
        guard isLinear else { return false }
        var ok = false
        for key in Key.pointerKeys {
            ok = setRaw(Self.disabledRaw, for: key) || ok
        }
        return ok
    }

    // MARK: - Optional: linear mouse with adjustable gain (mice only)

    /// For mice only: use Apple's linear-scaling path, which makes pointer gain
    /// constant and equal to `gain` (Windows "EPP off" + sensitivity slider).
    /// Trackpad-type services ignore this flag, which is why Decelerate defaults to
    /// the negative-sentinel method above.
    @discardableResult
    func enableMouseLinearGain(_ gain: Double) -> Bool {
        // Snapshot the two keys we are about to overwrite.
        if !isLinear {
            for key in [Key.mouse, Key.linearMouse] {
                if let raw = rawValue(for: key), raw >= 0 { snapshot[key] = raw }
            }
        }
        let gainRaw = Int32((gain * 65536.0).rounded())
        return setRaw(gainRaw, for: .mouse) && setRaw(1, for: .linearMouse)
    }
}
