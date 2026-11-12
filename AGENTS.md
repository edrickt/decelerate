# Decelerate agent notes

Native macOS menu bar app (Swift, SwiftUI, AppKit, one Xcode project, no dependencies) that controls pointer acceleration. Read `docs/agents/codebase-map.md` before the first broad search (`ls`, tree-wide grep/glob, or opening whole directories); it is the routing table for every task.

## Layout

- `Decelerate/App/` - entry point, app delegate, global `AppState`.
- `Decelerate/Core/` - HID layers, apply engine, curve math, settings and persistence.
- `Decelerate/UI/` - menu bar panel, Settings window, reusable components.
- `Scripts/` - build, install, screenshot and icon scripts.
- `Tools/Probe/` - research probes and captured evidence; `Notes/` - acceleration research write-ups.
- `docs/` - screenshots only. See the map's `Don't read` section before opening generated trees.

## Start here

- `Decelerate/App/DecelerateApp.swift` - scenes, app delegate, dev/QA launch flags.
- `Decelerate/App/AppState.swift` - the observable model every view and action goes through.
- `Decelerate/Core/AccelerationController.swift` - apply, retry and restore engine.
- `Decelerate/Core/HIDPointerControl.swift` and `Decelerate/Core/HIDServiceBridge.swift` - the two HID write paths.
- `Decelerate/Core/AccelerationCurveBuilder.swift` - blend and speed math.

Do not read `build/`, `build-ui/`, `dist/`, `Tools/Probe/bin/` or `Tools/Probe/out/` unless the task explicitly needs build output; the map explains each.

## Build and run

There is no test target (`xcodebuild -list` shows only the app). Verification is build plus a manual run plus the probes; see the map's `Tests` section for the full path.

```sh
./Scripts/build.sh                 # Debug build, stages dist/Decelerate.app
./Scripts/build.sh Release run     # Release build, stage, launch
./Scripts/install.sh               # Release build, install to ~/Applications
```

Preview UI without the menu bar:

```sh
dist/Decelerate.app/Contents/MacOS/Decelerate --preview-panel
dist/Decelerate.app/Contents/MacOS/Decelerate --preview-settings
```

Manual checks (all from the repo root):

```sh
DECELERATE_DEBUG=1 dist/Decelerate.app/Contents/MacOS/Decelerate --quit-after 5
python3 Tools/Probe/check-state.py
./Tools/Probe/filterlog.sh 10 10
./Tools/Probe/build.sh
```

`DECELERATE_DEBUG=1` writes debug output to stderr. Quitting must restore the original pointer parameters. Developer-only launch flags and the development path table are documented in the README's `## Development` section instead of being repeated here.

Domain terms and the verified mechanism live in `Notes/acceleration-research.md` and `Notes/acceleration-amount-research.md`; read them only when changing the apply path or curve math.
