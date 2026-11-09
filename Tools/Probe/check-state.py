#!/usr/bin/env python3
"""Read-only snapshot of macOS HID pointer-acceleration state.

Prints:
  * IOHIDSystem.HIDParameters (kernel-global HID parameter dictionary)
  * HIDEventServiceProperties (per-event-service user preference mirror) for every entry
  * NSGlobalDomain mouse/trackpad defaults
Used by the Decelerate probes before/after each write experiment.
"""
import json
import plistlib
import subprocess
import sys

KEYS = [
    "HIDUseLinearScalingMouseAcceleration",
    "HIDPointerAcceleration",
    "HIDMouseAcceleration",
    "HIDTrackpadAcceleration",
    "HIDScrollAcceleration",
    "HIDTrackpadScrollAcceleration",
    "HIDMouseScrollAcceleration",
]


def ioreg_root(*args):
    return plistlib.loads(subprocess.run(["ioreg", "-a", "-l", "-w", "0", *args],
                                         capture_output=True).stdout)


def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)


def main():
    root = ioreg_root()
    out = {"IOHIDSystem.HIDParameters": {}, "services": {}, "defaults": {}}
    for cls in ("IOHIDSystem",):
        for e in walk(root):
            if e.get("IOClass") == cls and "HIDParameters" in e:
                p = e["HIDParameters"]
                out["IOHIDSystem.HIDParameters"] = {k: p[k] for k in KEYS if k in p}
                break
    for e in walk(root):
        props = e.get("HIDEventServiceProperties")
        if not isinstance(props, dict):
            continue
        sel = {k: props[k] for k in KEYS if k in props}
        if not sel:
            continue
        name = f"{e.get('IOClass','?')}@{e.get('IORegistryEntryID','?')}"
        # multiple entries share identical values; collapse by value tuple
        out["services"].setdefault(json.dumps(sel, sort_keys=True), []).append(name)
    for k in ("com.apple.mouse.scaling", "com.apple.trackpad.scaling",
              "com.apple.mouse.linear", "com.apple.trackpad.linear"):
        r = subprocess.run(["defaults", "read", "-g", k], capture_output=True, text=True)
        out["defaults"][k] = r.stdout.strip() if r.returncode == 0 else "<absent>"
    print(json.dumps(out, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
