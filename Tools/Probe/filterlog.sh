#!/bin/bash
# filterlog.sh — read-only view of the live IOHIDPointerScrollFilter decisions.
#
# macOS' WindowServer hosts IOHIDEventSystem and logs (at default log level) exactly
# when it recomputes pointer acceleration: which key it used, the value, and whether
# acceleration ended up enabled or disabled. This is the ground truth for "did my
# property write actually reach the live accelerator?" — no root required.
#
# Usage: ./filterlog.sh [seconds] [lines]
#   ./filterlog.sh            # last 30 s, last 20 relevant lines
#   ./filterlog.sh 5 10       # last 5 s
#
# Look for lines like:
#   [4295750788] Pointer acceleration (disabled) HIDTrackpadAcceleration:-65536 ...
#   [4295750788] Pointer acceleration (enabled) HIDTrackpadAcceleration:131072 ...
# 4295750788 (0x1000bf484) is the built-in trackpad's service on this machine.

set -euo pipefail
SECS="${1:-30}"
LINES="${2:-20}"

log show --last "${SECS}s" \
    --predicate 'process == "WindowServer" AND subsystem == "com.apple.iohid"' 2>/dev/null \
  | grep 'IOHIDPointerScrollFilter' \
  | grep -E 'Acceleration key|Pointer acceleration|Scroll acceleration' \
  | sed -E 's/.*(IOHIDPointerScrollFilter[^]]*\])\s*/\1 /' \
  | tail -n "${LINES}"
