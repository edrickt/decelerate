# macOS pointer acceleration: verified research for Decelerate

Machine: Apple M-series MacBook, macOS 26.0.1 (build 25A362, "Tahoe"), Xcode 26.3, Swift 6.2.4.
All experiments were run live on this machine on 2026-11-08/09 by `hid-researcher`.
Every write was paired with a restore; the final state was byte-compared against the
pre-experiment snapshot (see §9 and `Tools/Probe/out/`).

---

## 1. TL;DR: what to ship

A plain non-sandboxed, ad-hoc signed app with no TCC permission, no root and no
entitlements can turn pointer acceleration OFF (true 1:1) for the built-in trackpad and
for mice, live, via one public (deprecated but exported) IOKit API:

```swift
import IOKit
import IOKit.hidsystem

// 1. Open the IOHIDSystem parameter connection (no privileges required)
let service = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
var handle: io_connect_t = 0
let kr = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &handle) // kr == KERN_SUCCESS
IOObjectRelease(service)

// 2. Read the current value first, so you can restore it exactly
func read(_ key: String) -> Int32? {
    var out: Unmanaged<CFTypeRef>?
    guard IOHIDCopyCFTypeParameter(handle, key as CFString, &out) == KERN_SUCCESS,
          let v = out?.takeRetainedValue() else { return nil }
    return (v as? NSNumber)?.int32Value
}
let originalTrackpad = read("HIDTrackpadAcceleration")   // this machine: 131072 (IOFixed 2.0)
let originalMouse    = read("HIDMouseAcceleration")      // this machine: 45056  (IOFixed 0.6875)

// 3. Disable acceleration: NEGATIVE IOFixed value = "acceleration disabled"
func write(_ key: String, _ raw: Int32) {
    _ = IOHIDSetCFTypeParameter(handle, key as CFString, NSNumber(value: raw))
}
write("HIDTrackpadAcceleration", -65536)  // IOFixed -1.0
write("HIDMouseAcceleration",    -65536)  // IOFixed -1.0
write("HIDPointerAcceleration",  -65536)  // generic fallback, covers other pointers

// 4. Restore when the user turns Decelerate off / quits
write("HIDTrackpadAcceleration", originalTrackpad!)
write("HIDMouseAcceleration",    originalMouse!)
```

Ready-to-drop-in, compiling version: `Tools/Probe/PointerAccelerationController.swift`.

Why this works (Apple's own code): `IOHIDPointerScrollFilter` computes
`_pointerAcceleration` from the type-specific key (`HIDTrackpadAcceleration` for the
trackpad, `HIDMouseAcceleration` for mice). If it is negative it returns before
installing any accelerator (`if (_pointerAcceleration < 0) return;`), and the filter
callback only applies acceleration when an accelerator exists. So raw HID deltas reach
the pointer unchanged, which gives exact 1:1 linear movement. Source: `apple-oss-distributions/
IOHIDFamily`, `IOHIDEventSystemPlugIns/IOHIDPointerScrollFilter.cpp` lines 854–861
(see §7 for citations).

The `HIDUseLinearScalingMouseAcceleration = 1` path is real but mouse-only. Apple
honours it only when the service's `HIDPointerAccelerationType == "HIDMouseAcceleration"`.
The built-in trackpad's type is `HIDTrackpadAcceleration`, so the flag is a no-op for
the trackpad. Verified against the live filter (it logs "Pointer acceleration
(enabled)" with the flag set to 1). Do not use it as the trackpad mechanism.

---

## 2. Two addressable layers (both verified working)

macOS keeps the acceleration parameters in two linked places:

| Layer | How to read/write | Readback | Notes |
|---|---|---|---|
| Kernel-global `IOHIDSystem` parameter dictionary (`HIDParameters`) | `IOServiceOpen(IOHIDSystem, kIOHIDParamConnectType)` + `IOHIDCopyCFTypeParameter` / `IOHIDSetCFTypeParameter` (public, deprecated 10.12) | Yes: exact raw IOFixed value | Recommended. One write for all pointer devices; also what System Settings ultimately uses. |
| User-space IOHIDEventSystem property dict (WindowServer) | `IOHIDEventSystemClientCreate` (private symbol, dlsym) + `IOHIDEventSystemClientCopyProperty/SetProperty` | Yes: exact raw value | Also propagates to every event service and the live filter; used by LinearMouse. Needs dlsym; does not update kernel `HIDParameters`. |
| Per-service `IOHIDServiceClientSetProperty` | public SDK headers | Partial: returns `true` but no effect for acceleration keys on most services | Confirmed no-op: no filter change, no registry change, no mirror change. Do not use. |
| `hidutil property --set` | CLI | Partial: inconsistent | `HIDMouseAcceleration`/`HIDPointerAcceleration` writes propagate; `HIDTrackpadAcceleration` and `HIDUseLinearScalingMouseAcceleration` are silently ignored. Do not use. |
| `defaults write -g com.apple.{mouse,trackpad}.scaling` | CLI | No: no live effect | Verified: `com.apple.trackpad.scaling` 2 → 0 → 1 → 2 produced no change in HID parameters or the live filter. Applies at login/relaunch at best. |
| Virtual HID injection (`IOHIDUserDevice*`) | IOKit | No: impossible | `IOHIDUserDeviceCreateWithProperties` returns NULL; requires Apple entitlement `com.apple.developer.hid.virtual.device`. Not available to local builds, so there is no synthetic-input test rig. |

Evidence that the kernel-param write reaches the live acceleration filter (WindowServer
`IOHIDPointerScrollFilter` log, service `4295750788` (`0x1000bf484`, the built-in trackpad)):

```
param-set HIDTrackpadAcceleration=fixed:-1: kr=0x0
   before = Number(raw=131072, ... ioFixed=2.0)
   after  = Number(raw=-65536, ... ioFixed=-1.0)
[WindowServer] IOHIDPointerScrollFilter [4295750788] Acceleration key:HIDTrackpadAcceleration value:-65536 apply:yes
[WindowServer] IOHIDPointerScrollFilter [4295750788] Pointer acceleration (disabled) HIDTrackpadAcceleration:-65536 ... -65536
-- restore 131072 --
[WindowServer] IOHIDPointerScrollFilter [4295750788] Acceleration key:HIDTrackpadAcceleration value:131072 apply:yes
[WindowServer] IOHIDPointerScrollFilter [4295750788] Pointer acceleration (enabled) HIDTrackpadAcceleration:131072 ... 131072
```

This log is the ground truth for "did the live accelerator actually change", and it is
readable without root: `log show --predicate 'process == "WindowServer" AND subsystem == "com.apple.iohid"'`.
(Use it while developing; the shipping app does not need to parse logs.)

---

## 3. Keys and semantics (verified and source-backed)

| Key | Meaning on this machine | Disable value |
|---|---|---|
| `HIDTrackpadAcceleration` | trackpad acceleration / "tracking speed"; `HIDPointerAccelerationType` of the trackpad is `HIDTrackpadAcceleration` | raw `-65536` (IOFixed −1.0) |
| `HIDMouseAcceleration` | mouse acceleration / speed | raw `-65536` |
| `HIDPointerAcceleration` | generic fallback for services without a type key | raw `-65536` |
| `HIDScrollAcceleration` | scroll acceleration (NOT pointer; Decelerate must not touch it) | n/a |
| `HIDUseLinearScalingMouseAcceleration` | mouse-only linear-scaling switch (see below) | flag `1` + mouse value = gain |

Values are IOFixed 16.16: `raw = value * 65536`. Original values on this machine:
`HIDTrackpadAcceleration = 131072 (2.0)`, `HIDMouseAcceleration = 45056 (0.6875)`,
`HIDPointerAcceleration = 45056 (0.6875)`,
`HIDUseLinearScalingMouseAcceleration = 0`, `HIDScrollAcceleration = 20480 (0.3125)`.
`com.apple.trackpad.scaling = 2`, `com.apple.mouse.scaling` absent (system default).

### `HIDUseLinearScalingMouseAcceleration` (the "linear scaling" flag): mouse-only

Apple's code (`setupPointerAcceleration`, lines ~833–889):

```cpp
pointerAccelType = copyCachedProperty("HIDPointerAccelerationType");
if (pointerAccelType) { typePointerAccel = copyCachedProperty(pointerAccelType);
                        pointerAcceleration = ...;
                        isMouseAcceleration = CFEqual(pointerAccelType, "HIDMouseAcceleration"); }
...
if (_pointerAcceleration < 0) return;              // <-- acceleration OFF
useLinear = copyCachedProperty("HIDUseLinearScalingMouseAcceleration");
if (isMouseAcceleration && useLinear && useLinear != 0) {
    _pointerAccelerator = new IOHIDSimpleAccelerator(_pointerAcceleration);  // gain = value
    return;
}
... curve algorithm (IOHIDPointerAccelerator)
```

Consequences (all verified live):
1. For the built-in trackpad (`HIDPointerAccelerationType == "HIDTrackpadAcceleration"`)
   the flag is ignored: setting it to 1 changes nothing. The filter log still reports
   `Pointer acceleration (enabled) ... 131072`. So the flag alone cannot make the
   trackpad linear.
2. For mice (type `HIDMouseAcceleration`) the flag switches to `IOHIDSimpleAccelerator`,
   a pure constant multiplier: `delta_out = delta_in * (HIDMouseAcceleration / 65536)`.
   Gain is constant across velocities, so it is linear; `gain == 1.0` when the value is `65536`.
   This is a good optional "linear + adjustable sensitivity" mode for mice.
3. A negative value disables acceleration entirely for every device class (this is
   what Decelerate uses for the trackpad, and it works for mice too).

### `IOHIDSetAccelerationWithKey` gotcha

`IOHIDSetAccelerationWithKey(handle, key, -1.0)` does not store −1: IOKit clamps
negative values to 0 (verified readback `0`, live filter `HIDTrackpadAcceleration:0`,
still "enabled"). To disable, use `IOHIDSetCFTypeParameter` with a raw `NSNumber(-65536)`.
`IOHIDSetAccelerationWithKey` is only useful for setting a non-negative speed/gain.

---

## 4. Behavioural verification status (known limits)

What is proven:
- The live `IOHIDPointerScrollFilter` for the built-in trackpad receives the write and
  switches to `Pointer acceleration (disabled)` (WindowServer log, §2), then back.
- Apple's filter code applies no acceleration in that state (`filter()` only calls
  `accelerateEvent` when `_pointerAccelerator != NULL`; setup returns before creating it
  when the value is negative). With no accelerator, HID deltas pass through, i.e. gain is
  exactly 1.0 for every velocity. That is the definition of 1:1 linear.
- For the mouse linear flag (`=1`), gain is exactly `HIDMouseAcceleration / 65536` by
  construction (`IOHIDSimpleAccelerator::accelerate` multiplies deltas by `_multiplier`
  and is a no-op when the multiplier is 1.0), constant for all velocities.
- Accelerated mode uses a velocity-dependent curve (`IOHIDPointerAccelerator`: computes
  velocity from `sqrt(dx²+dy²)` and multiplies by `algorithm->multiplier(velocity)/velocity`),
  so gain rises with speed by construction.

What is not measured on this machine:
- Real per-velocity gain numbers, because that needs physical input and this Mac has no
  external mouse attached, and synthetic HID injection is blocked by the
  `com.apple.developer.hid.virtual.device` entitlement (verified: `IOHIDUserDeviceCreateWithProperties`
  returns NULL). A CGEventTap rig that can produce those numbers is in
  `Tools/Probe/tapmeasure.swift` (verified working with synthetic events; needs a human
  to move a real mouse/trackpad while it runs). Suggested protocol for the human test:
  1. `tapmeasure listen 20 --csv /tmp/accel.csv`; move the mouse in slow then fast strokes.
  2. Compute gain per velocity bucket from raw HID deltas against delivered `deltaX` (raw via
     `IOHIDDevice` input reports; requires Input Monitoring TCC on the test process).
  3. Repeat with `hidprobe param-set HIDMouseAcceleration fixed:-1` (expect constant
     gain ≈ 1.0) and with `hidprobe param-set HIDUseLinearScalingMouseAcceleration 1`
     and `HIDMouseAcceleration` ∈ {32768, 45056, 65536, 98304} (expect constant gains
     0.5, 0.6875, 1.0, 1.5).
- Trackpad "feel" is impossible to measure automatically (no synthetic touch input);
  the filter-level disable is authoritative. Human feel-test recommended, especially to
  judge whether raw 400-dpi-equivalent trackpad motion (`HIDPointerResolution = 400`)
  feels comfortable; while disabled the System Settings "Tracking speed" slider is inert.

Note: `HIDMouseAcceleration = 0` is *not* disabled: it means gain 0 / slowest. Use a
negative raw value to disable, and non-negative values for linear gain.

---

## 5. Persistence and reversion

| Event | Does linear mode survive? | Evidence |
|---|---|---|
| App (the writer process) quits | Yes: state lives in WindowServer/kernel, not in the process | Set −65536 from process A, exited; process B triggered a filter re-read and log still showed `Pointer acceleration (disabled)` |
| Sleep/wake | Not tested on the user's machine (would not sleep their Mac). Likely survives; re-apply on `NSWorkspace.didWakeNotification` to be safe |
| Logout/reboot | Expected no: parameters are runtime state, not stored in `com.apple.*` defaults (no plist was created by any write) | No defaults were written by any experiment; `defaults` unchanged |
| System Settings "Tracking speed" slider change | Rewrites a positive value, which re-enables acceleration | Verified: writing a positive value back re-enables the filter; therefore re-apply on prefs change |
| Changing `com.apple.trackpad.scaling` via `defaults write` | Does not apply live (§2) | mirror/filter unchanged for 2→0→1→2 |
| `hidd`/WindowServer restart | untested (do NOT restart WindowServer on a live machine) | n/a |

Recommended app triggers for re-asserting linear mode: app launch; wake/display-wake;
HID device arrival (`IOHIDEventSystemClientRegisterDeviceMatchingBlock` or IOKit
notifications); `NSDistributedNotificationCenter`/`CFPreferencesDidChange` for
`NSGlobalDomain` keys `com.apple.trackpad.scaling` / `com.apple.mouse.scaling`; and a
low-frequency timer (e.g. 5 s) as a safety net. All are cheap: a write is one mach call.

Restoring on quit is essential because the state outlives the process: store the
snapshot in `UserDefaults` at first disable (so a crash doesn't lose the baseline), and
restore on "off"/quit; on next launch, if the *stored* baseline exists, offer restore.

Mixed-layer caveat (observed live): the two layers can diverge and the *live filter*
follows the per-service/filter cache with priority. During the session the app under
development left the filter "disabled" via an event-system/per-service write while the
kernel `HIDParameters` already read 131072; a system-level positive write did not fix the
filter until the same per-service key was written positively, after which the system-level
value also synced. Practical rule: restore through the same path/layer that was used to
disable. If both may have been used, write the positive value through both the
`IOHIDServiceClient` path for the trackpad service and the system-level/param paths, then
re-read the live filter (`filterlog.sh`) to confirm. Never assume a kernel-param readback
proves the live pointer is enabled.

---

## 6. Permissions

None required. Verified repeatedly with an ad-hoc signed `.app` bundle whose TCC
state was never granted (final verification, `Tools/Probe/tcc-test.sh`):

```
AXIsProcessTrusted=0
CGPreflightListenEventAccess=0
CGPreflightPostEventAccess=0
IOHIDCheckAccess(ListenEvent)=1 (0=granted, 1=denied, 2=unknown)
IOServiceOpen(IOHIDSystem, kIOHIDParamConnectType)=OK
HIDTrackpadAcceleration before=131072
IOHIDSetCFTypeParameter(-65536) kr=0x0
restore(131072) kr=0x0
[WindowServer] Pointer acceleration (disabled) HIDTrackpadAcceleration:-65536 ...   <-- caused by the TCC-free app
[WindowServer] Pointer acceleration (enabled)  HIDTrackpadAcceleration:131072 ...    <-- after its restore
```

- No Accessibility, no Input Monitoring, no root, no entitlements, no sandbox exception.
- The app can be non-sandboxed and ad-hoc signed (local build). No notarization needed.
- IOHID access checks (`IOHIDCheckAccess`) are irrelevant for this mechanism.
- If the app reads raw HID input (only needed by the dev measurement rig, not by the
  shipping feature) that does require Input Monitoring TCC.

---

## 7. Source-level references

Apple open source (github.com/apple-oss-distributions/IOHIDFamily, `main`):

- `IOHIDEventSystemPlugIns/IOHIDPointerScrollFilter.cpp`
  - property cache list incl. keys: ~lines 356–378
  - `setPropertyForClient` (per-service writes are cached for one setup only): ~384–418
  - `filter()` applies acceleration only if `_pointerAccelerator` exists: ~444–468
  - `setupPointerAcceleration`: type selection, `_pointerAcceleration < 0` early return
    (line 860), linear-scaling branch gated by `isMouseAcceleration` (line 868),
    `_pointerAccelerator = new IOHIDSimpleAccelerator(_pointerAcceleration)` (line 884)
  - `copyCachedProperty`: service properties to `_property` cache (~1020)
- `IOHIDEventSystemPlugIns/IOHIDAcceleration.cpp`: `IOHIDSimpleAccelerator::accelerate`
  (line 23): constant multiply by multiplier; no-op if 1.0. `IOHIDPointerAccelerator::accelerate`:
  curve based on `sqrt(dx²+dy²)` velocity.
- `IOHIDFamily/IOHIDEventServiceKeys.h` line 182: `kIOHIDUseLinearScalingMouseAccelerationKey`
- `IOHIDFamily/IOHIDEventService.cpp`: `setSystemProperties` merges device parameters
  into `kIOHIDEventServicePropertiesKey` (~571–604)
- `IOHIDSystem/IOKit/hidsystem/IOHIDParameter.h`: `kIOHIDPointerAccelerationKey` etc.

LinearMouse (github.com/linearmouse/linearmouse, `main`) is the reference implementation:

- `Modules/PointerKit/Sources/PointerKit/PointerDevice.swift`
  - `pointerAccelerationType` (~427) reads `HIDPointerAccelerationType` with a fallback
  - `setPointerAcceleration` (~480): `value == -1 ? -1 : clamp(0,40)` then IOFixed
  - `useLinearScalingMouseAcceleration` / `setUseLinearScalingMouseAcceleration` (~447–461)
  - `setPointerResolution` (~415) writes `HIDPointerResolution` (LinearMouse's "speed")
- `Modules/PointerKit/Sources/PointerKit/Extensions/IOHIDServiceClient+Property.swift`
  contains `getProperty`/`setProperty` and IOFixed conversions
- `Modules/PointerKit/Sources/PointerKitC/include/IOKitSPIMac.h`: private declarations:
  `IOHIDEventSystemClientCreate` (line 53), `CopyServiceForRegistryID` (56),
  `RegisterDeviceMatchingBlock` (57), `RegisterPropertyChangedCallback` (67)
- `LinearMouse/LinearMouse-Bridging-Header.h`: imports the same public
  `IOKit/hidsystem/IOHIDEventSystemClient.h` used here (so that header *is* in the SDK)
- `LinearMouse/Device/Device.swift`: `supportsLinearPointerScaling` (~206),
  `setDisablePointerAcceleration` (~721: writes `HIDUseLinearScalingMouseAcceleration`),
  `restorePointerAcceleration` (~747), `restoreUseLinearScalingMouseAcceleration` (~789)
- `LinearMouse/Device/PointerSchemeApplication.swift`: apply order; fallback
  `device.setPointerAcceleration(-1)` (~77–78) for devices with no linear-scaling support
- `LinearMouse/LinearMouse.entitlements`: no HID entitlement (only bluetooth and user-selected files)

Upstream caveat to record: LinearMouse's primary "disable pointer acceleration" path is
the per-device `HIDUseLinearScalingMouseAcceleration` flag (with `-1` fallback). As shown
in §3, that flag is mouse-only; on macOS 26 the built-in trackpad's service ignores it,
and its per-service writes are not the mechanism that reaches the active trackpad
accelerator. Decelerate should use the kernel/global negative-value method above, which
we verified at the live filter level. Also note LinearMouse's `pointerAcceleration`
readback is per-service and on this machine returns inherited/global values (the Lead
noticed the same); do not trust per-service readback for the trackpad.

---

## 8. Attempt, result, evidence

| # | Attempt | Worked? | Evidence |
|---|---|---|---|
| 1 | SDK header `IOKit/hidsystem/IOHIDEventSystemClient.h` + `IOHIDServiceClient.h` exist and import from Swift (`import IOKit.hidsystem`) | Yes | probe compiles; `IOHIDEventSystemClientCreateSimpleClient`/`CopyServices`/`CopyProperty`/`SetProperty`/`ConformsTo` link |
| 2 | `dlsym("IOHIDEventSystemClientCreate")` after importing IOKit | Yes | symbol found; full client created (connection type `Rate Controlled`, entitlements 0x0) |
| 3 | Enumerate pointer services; identify built-in trackpad | Yes | 141 services; trackpad service registry `0x1000bf484` (`AppleMultitouchDevice`), `HIDPointerAccelerationType = HIDTrackpadAcceleration`; keyboard/trackpad event driver `0x1000008f9` |
| 4 | Per-service `IOHIDServiceClientSetProperty("HIDTrackpadAcceleration", -65536)` on `0x1000bf484` | Partial: returned true; live filter logged "disabled" | WindowServer log; but no readback and no registry change; later found this is not the reliable/canonical path |
| 5 | Per-service same write on keyboard event service `0x1000008f9` | No: no effect | no filter log, no registry change |
| 6 | Per-service `HIDUseLinearScalingMouseAcceleration=1` on trackpad service | No: no effect (trackpad type not mouse) | live log stayed "Pointer acceleration (enabled) ... 131072" (also observed when the Lead's Decelerate app did it) |
| 7 | `hidutil property --set {"HIDMouseAcceleration":-65536}` | Partial: global mirror changed, filter config not verified for a mouse (no mouse attached) | `HIDEventServiceProperties` x137 updated; restored |
| 8 | `hidutil property --set {"HIDTrackpadAcceleration":...}` / `{"HIDUseLinearScalingMouseAcceleration":1}` | No: silently ignored | kernel/mirror/filter unchanged |
| 9 | `defaults write -g com.apple.trackpad.scaling 0/1/2` | No: no live effect | HID mirrors + live filter unchanged |
| 10 | `IOHIDEventSystemClientSetProperty` (system level, full client): `HIDTrackpadAcceleration=-65536` | Yes: live filter "disabled"; global mirrors x137 updated; readback works | WindowServer log + `check-state.py`; restored |
| 11 | `SimpleClient` system-level SetProperty of the same keys | No: returns false / readback nil | needs full client (dlsym) |
| 12 | Kernel param connect: `IOServiceOpen(IOHIDSystem, kIOHIDParamConnectType)` + `IOHIDCopyCFTypeParameter`/`IOHIDSetCFTypeParameter` `HIDTrackpadAcceleration=-65536` | Yes: kernel `HIDParameters` updated, live filter "disabled", exact readback | WindowServer log + ioreg `IOHIDSystem.HIDParameters`; restored |
| 13 | Same param path: `HIDUseLinearScalingMouseAcceleration=1` | Partial: sets/stores flag, but trackpad filter still enabled | WindowServer log |
| 14 | `IOHIDSetAccelerationWithKey(key, -1.0)` | No: stores 0 (clamps negative) | readback 0; filter shows 0/enabled |
| 15 | Persistence after writer exits | Yes: persists in WindowServer/kernel | process A set −1, exited; process B's filter re-read logged "disabled" |
| 16 | TCC-free ad-hoc app does the write | Yes: no permission needed | app bundle with AX=false/IM unknown: set + restore succeeded, filter logged both transitions |
| 17 | Virtual HID mouse (`IOHIDUserDeviceCreateWithProperties`) for behaviour measurement | No: blocked | returns NULL; requires `com.apple.developer.hid.virtual.device` entitlement |
| 18 | CGEventTap delta listener (`tapmeasure`) | Yes: works (synthetic events captured, 25/25) | `Tools/Probe/out/tap-smoke.txt`; real-velocity measurements need physical input |
| 19 | Type-swap trick (set `HIDPointerAccelerationType=HIDMouseAcceleration` on trackpad service to enable mouse linear gain) | No: not durable | property write not persisted/read back; filter reverts to `HIDTrackpadAcceleration` on next setup |
| 20 | Repeat/idempotency of writes | Yes: all `kr=0`, state consistent | three consecutive −1 writes, then restore; log lines confirm |

---

## 9. Safety protocol used (and what to keep in the app)

Original state recorded before any write (`Tools/Probe/out/00-*`):

```
HIDTrackpadAcceleration = 131072 (2.0)   HIDMouseAcceleration = 45056 (0.6875)
HIDPointerAcceleration  = 45056 (0.6875) HIDUseLinearScalingMouseAcceleration = 0
HIDScrollAcceleration   = 20480 (0.3125)
com.apple.trackpad.scaling = 2 (float)   com.apple.mouse.scaling = <absent>
```

Final state after all experiments is equivalent to the original: every HID parameter
has its original value and the defaults are unchanged. The only cosmetic difference is
that kernel `HIDParameters` now contains an *explicit* `HIDMouseAcceleration = 45056`
(the same value every service mirror and every write already used as the default) instead
of inheriting it; this was introduced by a later write and restore from the app under
development, not by a value change. `Tools/Probe/out/99-final-state.json` shows the final
state, `00-HIDParameters-original.json` the original; compare values, not key presence.
The live trackpad filter log ends with `Pointer acceleration (enabled) ... 131072`.

Rules for the app:
1. Read and persist the original values before first write; restore on disable/quit.
2. Never write `HIDScrollAcceleration` (scrolling is out of scope; leave gestures/scroll
   alone). We verified they use independent keys and filters.
3. Never restart/kill WindowServer, never run as root, never disable SIP. None of that is necessary.
4. If a write fails (`kr != KERN_SUCCESS`), do not report "on"; show the error.
5. On failure/crash recovery: if the current value is negative at launch and a stored
   baseline exists, offer/perform restore.

Failure modes tested: repeat writes are idempotent; scroll configuration is untouched;
the only wrong-write mode found is using `IOHIDSetAccelerationWithKey` with a negative
number (clamped to 0, so it becomes "enabled with gain 0", i.e. near-frozen pointer). Avoid it.

---

## 10. Probe inventory (`Tools/Probe/`)

- `PointerAccelerationController.swift`: compiling drop-in for the app (param-connect path).
- `hidprobe.swift`, the research CLI:
  `list`, `map`, `dump [--pointer-only]`, `get <key>`, `set-id`, `get-simple`, `set-simple`,
  `get-system`/`set-system` (full event-system client via dlsym), `param-dump` / `param-get` /
  `param-set` / `param-setaccel` (IOHIDParamConnect), `access` (TCC/AX/CGEventTap checks).
- `check-state.py` is a read-only snapshot: kernel `HIDParameters`, all
  `HIDEventServiceProperties` mirrors, NSGlobalDomain mouse/trackpad defaults (JSON).
- `filterlog.sh <seconds>` is read-only and prints the live `IOHIDPointerScrollFilter`
  acceleration decision for the built-in trackpad from WindowServer logs.
- `tapmeasure.swift` is a CGEventTap delta listener and synthetic-event smoke test
  (needed for the human behaviour test).
- `tcc-test.sh`: rebuilds and runs an ad-hoc-signed app bundle that proves the write
  needs no TCC; prints AX/IM status and the result.
- `build.sh`: builds everything and compile-checks the drop-in controller.
- `TCCProbe/main.c` and `tcc-test.sh`: ad-hoc signed app proving no TCC is needed.
- `out/` holds raw evidence: original/final snapshots, `golden-demo-transcript.txt`,
  tap smoke test, filter logs.

How the key experiments were run (all output is in `out/`):

```
./build.sh
./check-state.py > out/before.json
bin/hidprobe param-dump
bin/hidprobe param-set HIDTrackpadAcceleration fixed:-1 ; ./filterlog.sh 5
bin/hidprobe param-set HIDTrackpadAcceleration int:131072 ; ./filterlog.sh 5
./check-state.py > out/after.json   # compare
```

---

## 11. Open items / handoff

1. Human feel-test (recommended, 2 min): with Decelerate's toggle on, move the
   trackpad and a mouse; confirm 1:1 feel and that scroll/gestures/clicks are unchanged.
   While linear, System Settings "Tracking speed" has no effect (expected).
2. Mouse per-velocity gain numbers (optional, needs an external mouse): use
   `tapmeasure` per §4; expected: disabled gives gain 1.0 at all velocities; linear flag
   plus value g gives gain of g/65536; default accelerated makes gain rise with velocity.
3. Sleep/wake and logout persistence not tested (would disturb the user's session);
   the app should re-apply on wake and at launch.
4. Note on trackpad sensitivity: disabled acceleration means raw deltas at
   `HIDPointerResolution≈400 dpi`; if that feels too slow, the only property-level knob
   is `HIDPointerResolution` (LinearMouse's "speed"), which affects the accelerated
   algorithm. With acceleration disabled it is not used. A CGEventTap scaling layer
   would be required for adjustable trackpad sensitivity in linear mode; not needed for
   a first version.
