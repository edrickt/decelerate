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

open "$DEST_DIR/Decelerate.app" >/dev/null 2>&1 || true
# LaunchServices can report the just-replaced bundle as gone (error -600) when
# the old instance quits in the same moment, which leaves the app installed but
# not running. Retry briefly and say so, instead of claiming success.
for _ in 1 2 3 4 5; do
  pgrep -f "$DEST_DIR/Decelerate.app/Contents/MacOS/Decelerate" >/dev/null 2>&1 && break
  sleep 1
  open "$DEST_DIR/Decelerate.app" >/dev/null 2>&1 || true
done
if pgrep -f "$DEST_DIR/Decelerate.app/Contents/MacOS/Decelerate" >/dev/null 2>&1; then
  echo "Installed. Decelerate is running in the menu bar; 'Launch at login' is in its settings."
else
  echo "Installed to $DEST_DIR/Decelerate.app but it did not start; launch it from there." >&2
fi
