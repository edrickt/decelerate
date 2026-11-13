# decelerate codebase map

Verified against `3c71b721dfdd9f1bd4dae9b38a0c7eaae2844364` (2026-11-12). Native macOS menu-bar app: Swift 5, SwiftUI plus AppKit, one Xcode project, no package manager or third-party dependencies. Entry point is `Decelerate/App/DecelerateApp.swift` (`@main`). Learn `AccelerationController` first: it owns every system change that controls pointer acceleration, including snapshot and restore.

Maintenance: after adding, moving, or deleting a source file, update the File index and bump `Verified against` to the commit you checked.

## Orientation

- Menu-bar-only app (`LSUIElement`) that reduces pointer acceleration per device class, trackpad and mouse. 0% is 1:1 movement, 100% is macOS's own curve, values in between blend the two inside the HID pipeline.
- Entry and lifecycle: `Decelerate/App/DecelerateApp.swift:6` builds the `MenuBarExtra` and `Settings` scenes; its `AppDelegate` at `Decelerate/App/DecelerateApp.swift:67` starts the model, handles dev/QA launch flags, and restores on terminate.
- Single observable model: `Decelerate/App/AppState.swift:10` (`@MainActor`). Views own no state; all settings changes and HID actions go through it.
- Core engine: `Decelerate/Core/AccelerationController.swift:34` (`@MainActor`) snapshots originals, chooses a route per pointer class, installs curves or scales parameters, retries after wake/attach, and restores on quit.
- Two HID write paths: `Decelerate/Core/HIDPointerControl.swift:34` (IOHIDSystem parameter dictionary) and `Decelerate/Core/HIDServiceBridge.swift:82` (per-service event-system curves and properties). Blend math is isolated in `Decelerate/Core/AccelerationCurveBuilder.swift:31`.
- Domain docs: no CONTEXT, GLOSSARY or ADR files. The mechanism research is `Notes/acceleration-research.md`; the continuous-amount derivation is `Notes/acceleration-amount-research.md`. Read them only when changing the apply path or curve constants.
- Generated, not source: `build/`, `build-ui/`, `dist/`, `Tools/Probe/bin/`, `Tools/Probe/out/`.

## Layers

| Layer | Path | Owns | Read when |
|---|---|---|---|
| App shell and state | `Decelerate/App/` | scenes, app delegate, dev/QA arguments, observable model and actions | startup, menu bar wiring, adding a user-facing action |
| Apply engine | `Decelerate/Core/AccelerationController.swift` | snapshot, routing, writes, retries, restore | any behavior change to acceleration |
| HID parameter layer | `Decelerate/Core/HIDPointerControl.swift` | IOHIDSystem parameter connect, read/write, reopen, observer | parameter reads/writes and availability |
| HID service layer | `Decelerate/Core/HIDServiceBridge.swift` | event-system client, pointer services, curve/table/algorithm properties | installing or clearing per-device curves |
| Curve math | `Decelerate/Core/AccelerationCurveBuilder.swift` | blend toward identity plus speed multiplier | tuning the feel or fixing curve math |
| Models and persistence | `Decelerate/Core/PointerSettings.swift`, `Decelerate/Core/PreferencesStore.swift`, `Decelerate/Core/PointerDevice.swift` | pointer classes, defaults, UserDefaults keys, snapshot storage | settings, migration, persistence |
| UI | `Decelerate/UI/` | menu bar panel, Settings tabs, reusable views | visual or copy changes |
| Research tooling | `Tools/Probe/`, `Notes/` | probes, captured evidence, math derivation | verifying real HID behavior |

## Where things live

| Concern | Files |
|---|---|
| Menu bar panel | `Decelerate/UI/MenuBarPanel.swift:8`; cards and controls in `Decelerate/UI/Components/PointerClassCard.swift:10` |
| Settings window and tabs | `Decelerate/UI/SettingsView.swift:8` (General, Devices, About tabs in the same file) |
| Global state and user actions | `Decelerate/App/AppState.swift:10`; setters at `:168`, `:175`, `:183`, `:192` |
| Applying the current settings | `Decelerate/Core/AccelerationController.swift:267`; `performApply` at `:346` |
| Restore on quit | `Decelerate/App/DecelerateApp.swift:75` to `Decelerate/App/AppState.swift:96` to `Decelerate/Core/AccelerationController.swift:245` and `:488` |
| Restore macOS defaults button | `Decelerate/App/AppState.swift:227` |
| Wake / device-attach re-apply | `Decelerate/Core/AccelerationController.swift:210`, `:225`, `:285` |
| HID parameter read and write | `Decelerate/Core/HIDPointerControl.swift:80` (`readRaw`), `:95` (`writeRaw`), `:127` (`openParameterConnection`) |
| Connection reopen after wake | `Decelerate/Core/HIDPointerControl.swift:107` (`reopenIfNeeded`), `:118` (`forceReopen`) |
| Per-service user curves | `Decelerate/Core/HIDServiceBridge.swift:113` (`pointerServices`), `:183` (`setCurves`), `:200` (`clearCurves`) |
| Curve blend and speed math | `Decelerate/Core/AccelerationCurveBuilder.swift:39`; source-derived model in `Tools/Probe/curve_math.py` |
| Pointer classes, speed scale, defaults | `Decelerate/Core/PointerSettings.swift:9`, `:41`, `:68` |
| Preference keys and HID snapshots | `Decelerate/Core/PreferencesStore.swift:8` |
| Device list for the UI | `Decelerate/Core/HIDDeviceScanner.swift:10`, `Decelerate/Core/PointerDevice.swift:8` |
| Debug logging | `Decelerate/Core/DebugLog.swift:7` (enable with `DECELERATE_DEBUG=1`) |
| Dev and QA launch flags | `Decelerate/App/DecelerateApp.swift:92` (`handleDebugArguments`) |
| Launch at login | `Decelerate/App/AppState.swift:248` (`SMAppService`) |
| Status pill text | `Decelerate/UI/Components/StatusBadge.swift:7`; `AppState.statusPillLabel` extension at `:55` |
| Build and install | `Scripts/build.sh`, `Scripts/install.sh` |
| HID probes | `Tools/Probe/check-state.py`, `Tools/Probe/filterlog.sh`, `Tools/Probe/hidprobe.swift` |

## Task recipes

**Change how acceleration is applied.** Read `Decelerate/Core/AccelerationController.swift` (`performApply` routes per class and decides between curves and index scaling), `Decelerate/Core/HIDServiceBridge.swift` (how user curves are written), and `Decelerate/Core/HIDPointerControl.swift` (parameter read/write). Change the engine there, then verify with `./Scripts/build.sh` plus `./Tools/Probe/filterlog.sh 10 10` and `python3 Tools/Probe/check-state.py`.

**Tune the blend curve or speed scaling.** Read `Decelerate/Core/AccelerationCurveBuilder.swift` and the derivation in `Notes/acceleration-amount-research.md`; the executable model is `Tools/Probe/curve_math.py`. Change the builder, then compare against the research notes before rebuilding with `./Scripts/build.sh`.

**Add or change a user setting.** Read `Decelerate/Core/PointerSettings.swift` (`CategoryPreferences`, including its v1 boolean migration), `Decelerate/Core/PreferencesStore.swift` (keys and encode/decode), `Decelerate/App/AppState.swift` (published state and setters), then the relevant view in `Decelerate/UI/`. Build with `./Scripts/build.sh`; see `## Tests` for the preview flags.

**Change menu bar or Settings UI.** Read `Decelerate/UI/MenuBarPanel.swift` and `Decelerate/UI/SettingsView.swift`, then the component you touch in `Decelerate/UI/Components/`. Build with `./Scripts/build.sh`, then `dist/Decelerate.app/Contents/MacOS/Decelerate --preview-panel` or `--preview-settings`.

**Add a development or QA launch flag.** Read `Decelerate/App/DecelerateApp.swift:89` and `Decelerate/Core/DebugLog.swift`. Add the flag in `handleDebugArguments`, build with `./Scripts/build.sh`, and run the built binary with `DECELERATE_DEBUG=1` to see stderr output.

**Investigate real pointer or HID behavior.** Start read-only: `python3 Tools/Probe/check-state.py` for the live parameter snapshot and `./Tools/Probe/filterlog.sh 10 10` for the WindowServer filter's decisions. Build the probes with `./Tools/Probe/build.sh`; `Tools/Probe/README.md` lists the commands and safety rules. Do not add new system writes without restoring the original value.

## Tests

There is no test target and no unit-test suite. `xcodebuild -list -project Decelerate.xcodeproj` reports a single target, `Decelerate`, and the project contains no XCTest files, so there is no suite to claim coverage from.

The real verification path is build plus a manual run plus the research probes:

- Build: `./Scripts/build.sh` (Debug) or `./Scripts/build.sh Release`; both stage `dist/Decelerate.app`.
- UI smoke test without the menu bar: `dist/Decelerate.app/Contents/MacOS/Decelerate --preview-panel` and `--preview-settings`; capture one window with `swift Scripts/windowshot.swift Decelerate /tmp/panel.png`.
- Clean-quit behavior: `DECELERATE_DEBUG=1 dist/Decelerate.app/Contents/MacOS/Decelerate --quit-after 5`; stderr should show the restore path and the original parameters should come back.
- System state: `python3 Tools/Probe/check-state.py` before and after a run, and `./Tools/Probe/filterlog.sh 10 10` for live acceleration decisions. `Tools/Probe/filterlog.sh` exits 1 when no matching window of WindowServer log lines is found, which is not a failure.
- Probe build/typecheck: `./Tools/Probe/build.sh` builds `hidprobe` and `tapmeasure` and typechecks the drop-in controller.
- No fast/unit suite exists to run during a normal change. Every run above needs a signed-in macOS GUI session (macOS 14 or later), so there is no headless or CI path. `tapmeasure listen` is the only probe that needs Accessibility/Input Monitoring permission and physical input; it is research tooling, not a regression test.

## Don't read

- `build/` and `build-ui/` (about 200 MB and 120 MB of Xcode derived data and indexes).
- `dist/` (staged, ad-hoc-signed app bundle; rebuild with `Scripts/build.sh`).
- `Tools/Probe/bin/` (compiled probe binaries) and `Tools/Probe/out/` (raw research evidence: JSON, hex, transcripts; historical, not source).
- `Notes/acceleration-research.md` (465 lines) and `Notes/acceleration-amount-research.md` (551 lines) unless changing the mechanism or curve math.
- `docs/` (README screenshots), `Decelerate/Resources/` (asset catalog), `LICENSE`, `.git/`.

## Gotchas

- The negative-IOFixed sentinel described in `Notes/acceleration-research.md` and `Tools/Probe/PointerAccelerationController.swift` is the original research path; the shipping app never writes it (see `Notes/acceleration-amount-research.md` §13). For 0% it installs constant-gain user curves and writes the original positive parameter back (`Decelerate/Core/AccelerationController.swift:395`). Trust the code when editing the apply path.
- `UserPointerAccelCurvesKey` is write-only: copying it back returns nil even in the writing process (`Decelerate/Core/HIDServiceBridge.swift:192`). Verify installed curves with `./Tools/Probe/filterlog.sh`, not by read-back.
- `AppState` and `AccelerationController` are `@MainActor`; cross-thread work is bounced by the private `OnMain` helper in `Decelerate/Core/AccelerationController.swift`. Do not call the controller from a background context.
- Apply is deliberately retried: `retryDelays` at `Decelerate/Core/AccelerationController.swift:90` totals about 18 seconds after wake or attach, so a temporarily missing pointer class is not a bug.
- The snapshot protects itself: `lastWritten` values are never mistaken for the user's original, and `com.apple.*.scaling` defaults are treated as ground truth (`Decelerate/Core/AccelerationController.swift:125`, `:636`). Removing that logic can corrupt the restore.
- The app must stay non-sandboxed, hardened-runtime off, ad-hoc signed (`CODE_SIGN_IDENTITY = "-"` at `Decelerate.xcodeproj/project.pbxproj:257`; `ENABLE_APP_SANDBOX = NO` and `ENABLE_HARDENED_RUNTIME = NO` follow in the same build-settings block). Sandboxing or notarization changes can break the IOHIDSystem parameter connection.
- The Xcode project uses a filesystem-synchronized root group for `Decelerate/` (`Decelerate.xcodeproj/project.pbxproj:14`): new Swift files under that tree build automatically, but files added outside it require project edits.
- No event tap, root prompt, TCC API or entitlement file exists anywhere in `Decelerate/`; the permission stubs at `Decelerate/Core/AccelerationController.swift:706` always report "no permission needed". Do not add a permission UI on the assumption one is required.

## File index

`Decelerate/App/`

- `Decelerate/App/DecelerateApp.swift` - `@main` scenes, app delegate, dev/QA flags, preview windows, settings activation.
- `Decelerate/App/AppState.swift` - observable model, derived labels, preference setters, launch-at-login, restore-defaults, quit.

`Decelerate/Core/`

- `Decelerate/Core/AccelerationController.swift` - apply/restore engine: snapshot, route selection, curve/parameter writes, retry, external change handling.
- `Decelerate/Core/AccelerationCurveBuilder.swift` - pure blend and speed math for parametric curves.
- `Decelerate/Core/HIDPointerControl.swift` - IOHIDSystem parameter connection; read/write IOFixed parameters, reopen after wake, property observer.
- `Decelerate/Core/HIDServiceBridge.swift` - IOHIDEventSystem client; pointer service enumeration, curve/table/algorithm properties.
- `Decelerate/Core/HIDDeviceScanner.swift` - IOHIDManager device enumeration for the UI and attach/detach notifications.
- `Decelerate/Core/PointerDevice.swift` - device model used by the UI.
- `Decelerate/Core/PointerSettings.swift` - `PointerClass`, `SpeedScale` logarithmic mapping, `CategoryPreferences` and its Codable migration.
- `Decelerate/Core/PreferencesStore.swift` - UserDefaults wrapper, preference keys, persisted HID originals and last writes.
- `Decelerate/Core/DebugLog.swift` - stderr diagnostics gated by `DECELERATE_DEBUG=1`.

`Decelerate/UI/`

- `Decelerate/UI/MenuBarPanel.swift` - menu bar popover: header, status, pointer cards, Settings and Quit.
- `Decelerate/UI/SettingsView.swift` - Settings scenes with General, Devices and About tabs, including restore-defaults.
- `Decelerate/UI/Components/AppGlyph.swift` - gradient pointer glyph used in the panel and About tab.
- `Decelerate/UI/Components/DeviceRow.swift` - one connected-device row.
- `Decelerate/UI/Components/InlineBanner.swift` - inline error/empty-state notice.
- `Decelerate/UI/Components/PointerClassCard.swift` - per-class acceleration and speed sliders with captions.
- `Decelerate/UI/Components/StatusBadge.swift` - status pill plus the `AppState.statusPillLabel` helper.

`Scripts/`

- `Scripts/build.sh` - `xcodebuild` Debug/Release and stage into `dist/`.
- `Scripts/install.sh` - build Release and install to the user's Applications folder or `/Applications` with `--system`.
- `Scripts/windowshot.swift` - capture one app window to PNG via `screencapture`.
- `Scripts/generate-icon.py` - regenerate the asset-catalog app icon with Pillow.

`Tools/Probe/`

- `Tools/Probe/PointerAccelerationController.swift` - standalone drop-in controller used as a compile-time reference.
- `Tools/Probe/hidprobe.swift` - research CLI: services, properties, parameter reads/writes, TCC state.
- `Tools/Probe/tapmeasure.swift` - CGEventTap delta measurement and synthetic-event smoke test.
- `Tools/Probe/curve_math.py` - source-derived model of Apple's accelerators, blend curves and gain tables.
- `Tools/Probe/check-state.py` - read-only JSON snapshot of HID parameters, service mirrors and pointer defaults.
- `Tools/Probe/filterlog.sh` - read-only view of live `IOHIDPointerScrollFilter` decisions.
- `Tools/Probe/tcc-test.sh` - builds and runs an ad-hoc signed probe that proves no TCC permission is needed.
- `Tools/Probe/TCCProbe/main.c` - the minimal C probe used by `Tools/Probe/tcc-test.sh`.
- `Tools/Probe/build.sh` - builds the probes and typechecks the drop-in controller.
