#!/bin/bash
# tcc-test.sh — proves the pointer-acceleration write needs no TCC permission.
#
# Builds an ad-hoc signed app bundle containing a tiny binary that never asks for
# Accessibility/Input Monitoring, runs it with `open`, and prints:
#   * its AX / Input-Monitoring state (must be denied/unknown),
#   * whether the IOHIDParamConnect write succeeded,
#   * the live WindowServer IOHIDPointerScrollFilter transitions it caused.
# The app disables trackpad acceleration for ~0.6 s and restores the previous value.
set -euo pipefail
cd "$(dirname "$0")"
APP=/tmp/DecelerateTCCProbe.app
OUT=/tmp/decelerate-tcc-probe.txt
rm -rf "$APP" "$OUT"
mkdir -p "$APP/Contents/MacOS"
cp TCCProbe/Info.plist "$APP/Contents/Info.plist"
clang -O2 -o "$APP/Contents/MacOS/DecelerateTCCProbe" TCCProbe/main.c \
      -framework ApplicationServices -framework IOKit -framework CoreFoundation
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "== launching ad-hoc signed app bundle: $APP =="
open "$APP" || true
for _ in $(seq 1 50); do [ -f "$OUT" ] && break; sleep 0.1; done
[ -f "$OUT" ] || { open "$APP" || true; for _ in $(seq 1 50); do [ -f "$OUT" ] && break; sleep 0.1; done; }
cat "$OUT"
echo
echo "== live IOHIDPointerScrollFilter log (last 10 s) =="
./filterlog.sh 10 8 || true
