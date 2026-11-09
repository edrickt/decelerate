# Decelerate: research probes (macOS pointer acceleration)

Everything here was used to produce `../../Notes/acceleration-research.md`, on a real
Mac (macOS 26.0.1, build 25A362, Apple silicon). Build with `./build.sh`.

## The short version

The app needs no root, no TCC permission, no entitlement. It disables pointer
acceleration (true 1:1 movement) by writing a negative IOFixed value into IOHIDSystem's
global parameter dictionary, using the public (deprecated) `IOHIDParamConnectType` API:

```swift
let service = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
var handle: io_connect_t = 0
IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &handle)
IOObjectRelease(service)
// disable: raw IOFixed(-1.0)
IOHIDSetCFTypeParameter(handle, "HIDTrackpadAcceleration" as CFString, NSNumber(value: Int32(-65536)))
IOHIDSetCFTypeParameter(handle, "HIDMouseAcceleration"    as CFString, NSNumber(value: Int32(-65536)))
// restore: the values read with IOHIDCopyCFTypeParameter before disabling
```

`PointerAccelerationController.swift` is the compiling drop-in implementation.
`HIDUseLinearScalingMouseAcceleration = 1` is mouse-only and a no-op for the
built-in trackpad, so do not use it for the trackpad.

## Tools

| file | purpose |
|---|---|
| `PointerAccelerationController.swift` | drop-in controller for the app (param-connect path, snapshot/restore/reapply) |
| `hidprobe.swift` | research CLI: service enumeration, property dump, per-service writes, event-system-level writes, kernel param reads/writes, TCC checks |
| `check-state.py` | read-only JSON snapshot: kernel `HIDParameters`, all service mirrors, NSGlobalDomain mouse/trackpad defaults |
| `filterlog.sh` | read-only: live `IOHIDPointerScrollFilter` decisions from WindowServer logs (ground truth for "did the accelerator change") |
| `tapmeasure.swift` | CGEventTap delta listener + synthetic-event smoke test (for measuring gain with physical input) |
| `curve_math.py` | source-exact model of Apple's parametric + table accelerators; generates the continuous-amount blend curves, gain tables and fit/error analysis (`--analysis`, `--mouse`). See `../../Notes/acceleration-amount-research.md` |
| `TCCProbe/` + `tcc-test.sh` | builds an ad-hoc signed app that never asks for TCC and proves the write works; prints its AX/IM state and the live filter transitions |
| `out/` | raw evidence from the research session (snapshots, transcripts, logs) |

## Common commands

```bash
./build.sh
./check-state.py                       # where are the pointer params now?
bin/hidprobe param-dump                # kernel-global HID parameters (readable!)
bin/hidprobe param-set HIDTrackpadAcceleration fixed:-1   # DISABLE (raw -65536 = IOFixed -1.0)
bin/hidprobe param-set HIDTrackpadAcceleration int:131072 # restore this machine's original 2.0
./filterlog.sh 10                      # watch the live filter flip between enabled/disabled
./tcc-test.sh                          # prove no TCC is needed
```

Danger-free rule: every `param-set` that changes state has a matching read in
`param-dump`; capture the original first and restore it immediately (all scripts here do).

## Notes / limitations

- No external mouse was attached during research, so measured per-velocity gain numbers
  require a human to move a pointer while `tapmeasure listen` runs (see the notes §4).
- Continuous acceleration amount (task-3): install blended curves with
  `bin/hidprobe set-id <trackpadService> UserPointerAccelCurvesKey 'arrayjson:[...]'`
  and clear with `emptyarray`; verify via the WindowServer debug log
  (`table index 0` = user curve in use, `table index 7` = native fallback). Table
  installation does NOT work from user space (verified). See
  `Notes/acceleration-amount-research.md`.
- Synthetic HID injection is impossible locally: `IOHIDUserDeviceCreateWithProperties`
  requires Apple's `com.apple.developer.hid.virtual.device` entitlement and returns NULL.
- Do not use `defaults write -g com.apple.trackpad.scaling` (no live effect), per-service
  `IOHIDServiceClientSetProperty` (silently ineffective for these keys), or `hidutil
  property --set` for trackpad keys (silently ignored).
- Never kill/restart WindowServer; no root or SIP changes are needed for this feature.
