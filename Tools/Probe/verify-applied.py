#!/usr/bin/env python3
"""Read-only proof that Decelerate's curves are attached to the live HID services.

Why this exists
---------------
A pointer/scroll curve is written per HID *service* (`UserPointerAccelCurvesKey`)
and cached by that service's filter instance. macOS replaces pointer services
without telling anyone: the built-in trackpad gets a new one on every wake from
idle, sleep/wake does it for every device, and WindowServer re-creates them after
a session change. A replacement drops the curve, the HID parameters stay exactly
as Decelerate wrote them, and the pointer silently reverts to macOS acceleration
while the app still reports the settings as applied. The property cannot be read
back, so the only ground truth is Apple's own filter log in WindowServer.

This script compares what the app should have installed (its stored preferences)
with the live services and the filter log. It is the regression check for the
"deceleration and speed stopped working" class of bug; run it after touching the
apply path, the HID layer, or the wake/attach/watchdog triggers.

Usage
-----
    python3 Tools/Probe/verify-applied.py                # last 180 minutes
    python3 Tools/Probe/verify-applied.py --minutes 30   # shorter log window
    python3 Tools/Probe/verify-applied.py --verbose

Exit codes
----------
    0  every shaping class is attached to the live services
    1  a class is shaping but the live service has no curve (the bug)
    2  inconclusive: no log evidence for a live service, or preferences/probe
       are missing

Read-only: it never writes HID state. Build the probe first with
`./Tools/Probe/build.sh`.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys

DOMAIN = "com.decelerate.app"
PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", "hidprobe")

INIT_RE = re.compile(r"\[(\d+)\] Acceleration key:HID\w+ value:-?\d+ apply:no client:\(null\)")
# A written curve renders as `value:(` followed by the array contents; clearing it
# (restore, or back to native) writes an empty array, rendered as
# `value:(\n) apply:yes`. The two must be told apart, otherwise a cleared curve
# looks attached.
INSTALL_RES = {
    "pointer": re.compile(r"\[(\d+)\] Acceleration key:UserPointerAccelCurvesKey value:\(\s*\{"),
    "scroll": re.compile(r"\[(\d+)\] Acceleration key:UserScrollAccelCurvesKey value:\(\s*\{"),
}
CLEAR_RES = {
    "pointer": re.compile(r"\[(\d+)\] Acceleration key:UserPointerAccelCurvesKey value:\(\s*\)"),
    "scroll": re.compile(r"\[(\d+)\] Acceleration key:UserScrollAccelCurvesKey value:\(\s*\)"),
}

# Parameter keys each class shapes (mirrors AccelerationController).
POINTER_KEYS = {
    "trackpad": ["HIDTrackpadAcceleration"],
    "mouse": ["HIDMouseAcceleration", "HIDPointerAcceleration"],
}
SCROLL_KEYS = {
    "trackpad": ["HIDTrackpadScrollAcceleration"],
    "mouse": ["HIDMouseScrollAcceleration"],
}
FALLBACK_ORIGINALS = {
    "HIDTrackpadAcceleration": 131_072,
    "HIDMouseAcceleration": 45_056,
    "HIDPointerAcceleration": 45_056,
    "HIDTrackpadScrollAcceleration": 20_480,
    "HIDMouseScrollAcceleration": 20_480,
}


def run(command: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True)


def exported_preferences() -> dict:
    """The app's preferences, with the JSON payloads decoded."""
    result = run(["defaults", "export", DOMAIN, "-"])
    if result.returncode != 0 or not result.stdout:
        return {}
    try:
        raw = plistlib.loads(result.stdout.encode("utf-8", "surrogateescape"))
    except Exception:
        return {}
    preferences = {}
    for key, value in raw.items():
        if isinstance(value, (bytes, bytearray)):
            try:
                value = json.loads(bytes(value).decode("utf-8"))
            except Exception:
                continue
        preferences[key] = value
    return preferences


def live_services() -> list[dict]:
    if not os.path.exists(PROBE):
        print(f"missing {PROBE}; run ./Tools/Probe/build.sh", file=sys.stderr)
        raise SystemExit(2)
    result = run([PROBE, "pointers"])
    if result.returncode != 0:
        print(result.stderr.strip() or "hidprobe pointers failed", file=sys.stderr)
        raise SystemExit(2)
    services = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 2 or not fields[1].startswith("0x"):
            continue
        services.append({
            "class": fields[0],
            "id": int(fields[1], 16),
            "hex": fields[1],
            "pointer_curves": "curves=yes" in fields,
            "scroll_curves": "scrollcurves=yes" in fields,
        })
    return services


def live_parameter(key: str) -> int | None:
    result = run([PROBE, "param-get", key])
    match = re.search(r"raw=(-?\d+)", result.stdout)
    return int(match.group(1)) if match else None


def filter_events(minutes: int) -> dict[int, dict]:
    """Ordering of the filter's own log entries per service registry ID."""
    result = run([
        "log", "show", "--last", f"{minutes}m",
        # The default style (not --style compact) is the one that prints the
        # filter name; requiring it keeps unrelated ioHID log lines out.
        "--predicate", 'process == "WindowServer" AND subsystem == "com.apple.iohid"',
    ])
    events: dict[int, dict] = {}
    text = result.stdout
    for match in INIT_RE.finditer(text):
        events.setdefault(int(match.group(1)), {})["init"] = match.start()
    for kind in ("pointer", "scroll"):
        for state, pattern in (("installed", INSTALL_RES[kind]), ("cleared", CLEAR_RES[kind])):
            for match in pattern.finditer(text):
                entry = events.setdefault(int(match.group(1)), {})
                previous = entry.get(kind)
                if previous is None or match.start() > previous[0]:
                    entry[kind] = (match.start(), state)
    return events


def categories(preferences: dict) -> dict[str, dict]:
    """Per-class preferences, defaulted the way CategoryPreferences defaults."""
    result = {}
    for pointer_class in ("trackpad", "mouse"):
        stored = preferences.get(f"pointer.{pointer_class}")
        stored = stored if isinstance(stored, dict) else {}
        result[pointer_class] = {
            "amount": float(stored.get("accelerationAmount", 1.0)),
            "speed": float(stored.get("speedMultiplier", 1.0)),
            "scroll_amount": float(stored.get("scrollAccelerationAmount", 1.0)),
            "scroll_speed": float(stored.get("scrollSpeedMultiplier", 1.0)),
            "invert": bool(stored.get("invertScroll", False)),
        }
    return result


def shapes_pointer(category: dict) -> bool:
    return category["amount"] < 0.995 or abs(category["speed"] - 1.0) >= 0.01


def shapes_scroll(category: dict) -> bool:
    return (
        category["scroll_amount"] < 0.995
        or abs(category["scroll_speed"] - 1.0) >= 0.01
        or category["invert"]
    )


def curve_missing(services: list[dict], events: dict, kind: str) -> tuple[list[dict], bool]:
    """Services with no curve evidence, and whether the log is simply too short."""
    missing, unknown = [], False
    for service in services:
        service_events = events.get(service["id"], {})
        curve = service_events.get(kind)
        init = service_events.get("init")
        if curve is not None:
            offset, state = curve
            if state == "installed" and (init is None or offset > init):
                continue
        elif init is None:
            unknown = True
            continue
        missing.append(service)
    return missing, unknown


def missing_reason(service: dict, events: dict, kind: str) -> str:
    service_events = events.get(service["id"], {})
    curve = service_events.get(kind)
    if curve is not None:
        if curve[1] == "cleared":
            return "curve was cleared (restore or native)"
        return "curve written before this service instance existed"
    return "no curve ever written for this service"


def check_pointer(pointer_class: str, services: list[dict], events: dict, originals: dict) -> tuple[str, str]:
    missing, unknown = curve_missing(services, events, "pointer")
    if not missing and not unknown:
        return "ok", "curve attached to " + ", ".join(s["hex"] for s in services)
    if unknown:
        return "unknown", "no filter log history for " + ", ".join(s["hex"] for s in services)
    # The table route shapes by scaling the acceleration index instead of
    # installing a curve, and only applies to services without parametric curves.
    if all(service["pointer_curves"] is False for service in services):
        for key in POINTER_KEYS[pointer_class]:
            live = live_parameter(key)
            base = originals.get(key, FALLBACK_ORIGINALS.get(key, 0))
            if live is not None and base and live != base:
                return "ok", f"index scaled {key}={live} (base {base}): table route"
    detail = "; ".join(f"{s['hex']}: {missing_reason(s, events, 'pointer')}" for s in missing)
    return "fail", detail


def check_scroll(pointer_class: str, category: dict, services: list[dict], events: dict, originals: dict) -> tuple[str, str]:
    missing, unknown = curve_missing(services, events, "scroll")
    if not missing and not unknown:
        return "ok", "scroll curve attached to " + ", ".join(s["hex"] for s in services)
    if unknown:
        return "unknown", "no filter log history for " + ", ".join(s["hex"] for s in services)
    # Mirrors applyScroll: without native scroll curves, a plain amount at 1x
    # with no inversion uses the scaled index instead of a curve.
    table_route = (
        all(service["scroll_curves"] is False for service in services)
        and abs(category["scroll_speed"] - 1.0) < 0.01
        and not category["invert"]
        and category["scroll_amount"] < 0.995
    )
    if table_route:
        for key in SCROLL_KEYS[pointer_class]:
            live = live_parameter(key)
            base = originals.get(key, FALLBACK_ORIGINALS.get(key, 0))
            if live is not None and base and live < base:
                return "ok", f"scroll index scaled {key}={live} (base {base})"
    detail = "; ".join(f"{s['hex']}: {missing_reason(s, events, 'scroll')}" for s in missing)
    return "fail", detail


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--minutes", type=int, default=180, help="filter log window in minutes (default 180)")
    parser.add_argument("--verbose", action="store_true", help="print per-service log evidence")
    arguments = parser.parse_args()

    preferences = exported_preferences()
    if not preferences:
        print(f"no preferences for {DOMAIN}: is the app installed and has it run?", file=sys.stderr)
        return 2
    originals = preferences.get("system.accelerationOriginals")
    originals = originals if isinstance(originals, dict) else {}
    per_class = categories(preferences)

    if not any(shapes_pointer(c) or shapes_scroll(c) for c in per_class.values()):
        print("nothing is being shaped: Decelerate is at macOS defaults")
        return 0

    services = live_services()
    events = filter_events(arguments.minutes)
    app_running = run(["pgrep", "-f", "Decelerate.app/Contents/MacOS/Decelerate"]).returncode == 0

    print(f"live pointer services: {len(services)} | app running: {'yes' if app_running else 'NO'}")
    for service in services:
        print(
            f"  {service['hex']} {service['class']:8s} "
            f"pointer-curves={'yes' if service['pointer_curves'] else 'no '} "
            f"scroll-curves={'yes' if service['scroll_curves'] else 'no '}"
        )

    verdict = 0
    for pointer_class in ("trackpad", "mouse"):
        category = per_class[pointer_class]
        class_services = [service for service in services if service["class"] == pointer_class]
        for kind, shaping in (("pointer", shapes_pointer(category)), ("scroll", shapes_scroll(category))):
            if not shaping:
                print(f"{pointer_class} {kind:7s}: skip    set to macOS default")
                continue
            if not class_services:
                print(f"{pointer_class} {kind:7s}: skip    no device of this class attached")
                continue
            if kind == "pointer":
                status, detail = check_pointer(pointer_class, class_services, events, originals)
            else:
                status, detail = check_scroll(pointer_class, category, class_services, events, originals)
            print(f"{pointer_class} {kind:7s}: {status.upper():7s} {detail}")
            if status == "fail":
                verdict = max(verdict, 1)
            elif status == "unknown":
                verdict = max(verdict, 2)
            if arguments.verbose:
                for service in class_services:
                    print(f"    {service['hex']}: {events.get(service['id'], {})}")

    if verdict == 0:
        print("PASS: every shaped class is attached to the live HID services")
    elif verdict == 1:
        print("FAIL: a shaped class is not attached to its live HID service (the reported bug)")
    else:
        print("INCONCLUSIVE: not enough filter log history; rerun with a larger --minutes")
    if not app_running:
        print("note: the app is not running; installed curves survive until macOS replaces the service")
    return verdict


if __name__ == "__main__":
    sys.exit(main())
