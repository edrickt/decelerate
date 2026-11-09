#!/bin/bash
# Build Decelerate.app and stage it in dist/.
#
#   ./Scripts/build.sh              # Debug build
#   ./Scripts/build.sh Release      # Release build
#   ./Scripts/build.sh Release run  # build, stage, and launch
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
ACTION="${2:-}"

xcodebuild \
  -project Decelerate.xcodeproj \
  -scheme Decelerate \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  -quiet \
  build

APP="build/Build/Products/$CONFIG/Decelerate.app"
[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }

rm -rf dist
mkdir -p dist
cp -R "$APP" dist/
echo "Built dist/Decelerate.app ($CONFIG)"

if [[ "$ACTION" == "run" ]]; then
  open dist/Decelerate.app
fi
