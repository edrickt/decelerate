#!/bin/bash
# Build/verify the Decelerate research probes.
# Usage: ./build.sh          # build tools + compile-check the drop-in controller
#        ./build.sh --demo   # also run a disable/restore demo (briefly changes pointer settings)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin

echo "== building hidprobe (research CLI) =="
swiftc -O -o bin/hidprobe hidprobe.swift

echo "== building tapmeasure (CGEventTap delta rig) =="
swiftc -O -o bin/tapmeasure tapmeasure.swift

echo "== compile-checking PointerAccelerationController.swift (drop-in code for the app) =="
swiftc -parse-as-library -typecheck PointerAccelerationController.swift

echo "== commands =="
cat <<'EOT'
  bin/hidprobe access                 # TCC/AX status of this process + CGEventTap smoke test
  bin/hidprobe map                    # every IOHIDEventSystem service + registry class
  bin/hidprobe dump --pointer-only    # pointer services: props + full IORegistry dump
  bin/hidprobe param-dump             # kernel HIDParameters via IOHIDParamConnect (read-only)
  bin/hidprobe param-set HIDTrackpadAcceleration fixed:-1     # disable (IOFixed -1.0 = raw -65536)
  bin/hidprobe param-set HIDTrackpadAcceleration int:131072   # restore value 2.0
  bin/hidprobe get-system HIDTrackpadAcceleration             # same values via the event system
  ./check-state.py                    # HID params / mirrors / defaults snapshot (read-only)
  ./filterlog.sh 30                   # live IOHIDPointerScrollFilter decisions (read-only)
  ./tcc-test.sh                       # proves the write needs no TCC (ad-hoc signed app bundle)
  bin/tapmeasure listen 20 --csv /tmp/accel.csv   # measure delivered deltas (needs physical input)
EOT

if [ "${1:-}" = "--demo" ]; then
  echo "== demo: disable then restore trackpad acceleration =="
  ORIG=$(bin/hidprobe param-get HIDTrackpadAcceleration | grep -o 'raw=[-0-9]*' | head -1 | cut -d= -f2)
  echo "original raw = $ORIG"
  bin/hidprobe param-set HIDTrackpadAcceleration fixed:-1
  sleep 1; ./filterlog.sh 5 6
  echo "-- restoring --"
  bin/hidprobe param-set HIDTrackpadAcceleration "int:$ORIG"
  sleep 1; ./filterlog.sh 5 6
fi
