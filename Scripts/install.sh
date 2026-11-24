#!/bin/bash
# Build Decelerate (Release), install it into ~/Applications, and launch it.
#
#   ./Scripts/install.sh              # install for the current user (no admin)
#   ./Scripts/install.sh --system     # install into /Applications (may need admin)
#
# Exits non-zero when the running copy cannot be stopped, when the copy fails, or
# when the app that ends up running is not the one just installed.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST_DIR="$HOME/Applications"
if [[ "${1:-}" == "--system" ]]; then
  DEST_DIR="/Applications"
fi

DEST="$DEST_DIR/Decelerate.app"
BIN="$DEST/Contents/MacOS/Decelerate"
BUNDLE_ID="com.decelerate.app"

./Scripts/build.sh Release

echo "Installing to $DEST"
mkdir -p "$DEST_DIR"

# Stop the running copy before replacing its bundle. Replacing a bundle under a
# live process leaves the old build running from a deleted directory (its argv
# does not change), and `open` would only re-activate that instance because
# LaunchServices keys on the bundle identifier -- so the "installed" message
# could describe the previous build.
#
# A failed quit is a real failure (no Automation permission, an app stuck in its
# restore path), not something to swallow: copying over a running build is what
# made the old script lie.
if pgrep -x Decelerate >/dev/null 2>&1; then
  echo "Quitting the running copy so it can be replaced"
  if ! osascript -e "tell application id \"$BUNDLE_ID\" to quit"; then
    echo "error: could not ask Decelerate to quit. Quit it from the menu bar and re-run." >&2
    exit 1
  fi
  for _ in $(seq 1 50); do
    pgrep -x Decelerate >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x Decelerate >/dev/null 2>&1; then
    echo "error: Decelerate is still running (pid $(pgrep -x Decelerate | tr '\n' ' ')). Quit it and re-run." >&2
    exit 1
  fi
fi

rm -rf "$DEST"
cp -R dist/Decelerate.app "$DEST_DIR/"
[[ -x "$BIN" ]] || { echo "error: $BIN is missing after the copy" >&2; exit 1; }

if ! open "$DEST"; then
  echo "error: installed to $DEST but macOS could not launch it; open it from there." >&2
  exit 1
fi

# LaunchServices can report the just-replaced bundle as gone (error -600) for a
# moment after the old instance quits, so retry briefly.
for _ in $(seq 1 25); do
  pgrep -x Decelerate >/dev/null 2>&1 && break
  sleep 0.2
  open "$DEST" >/dev/null 2>&1 || true
done

RUNNING_PIDS="$(pgrep -x Decelerate || true)"
if [[ -z "$RUNNING_PIDS" ]]; then
  echo "error: installed to $DEST but it did not start; launch it from there." >&2
  exit 1
fi

# Only claim success for the build that was just installed: check that a running
# process really is executing the new binary and not a stale instance.
NEW_FOUND=0
for pid in $RUNNING_PIDS; do
  if [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == "$BIN" ]]; then
    NEW_FOUND=1
    break
  fi
done
if [[ "$NEW_FOUND" -ne 1 ]]; then
  echo "error: a Decelerate process is running, but not $BIN (pid $RUNNING_PIDS)." >&2
  echo "       Quit it and launch $DEST manually." >&2
  exit 1
fi

echo "Installed. Decelerate is running in the menu bar; 'Launch at login' is in its settings."
