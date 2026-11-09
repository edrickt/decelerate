#!/bin/bash
# Build Decelerate (Release), install it into ~/Applications, and launch it.
#
#   ./Scripts/install.sh              # install for the current user (no admin)
#   ./Scripts/install.sh --system     # install into /Applications (may need admin)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST_DIR="$HOME/Applications"
if [[ "${1:-}" == "--system" ]]; then
  DEST_DIR="/Applications"
fi

./Scripts/build.sh Release

echo "Installing to $DEST_DIR/Decelerate.app"
mkdir -p "$DEST_DIR"
# Quit a running copy first so the replace is clean. `quit` sends SIGTERM; the
# restore-on-quit path runs on the app's own terminate, so prefer AppleScript.
osascript -e 'tell application "Decelerate" to quit' >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$DEST_DIR/Decelerate.app"
cp -R dist/Decelerate.app "$DEST_DIR/"

open "$DEST_DIR/Decelerate.app"
echo "Installed. Decelerate is in the menu bar; enable 'Launch at login' in its settings."
