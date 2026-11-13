# Decelerate code-quality audit: 2026-11-12

| | |
|---|---|
| Repository | `decelerate` (`/Users/etm1air/Files/Github/decelerate`) |
| Baseline | `5348136ef9d3f205b706f5dbe2c4810f4a4ba401` (`main`; working tree clean at audit start) |
| Release version | pending. `MARKETING_VERSION` is still 1.4.2 (10); no version file was changed by this audit |
| Audit date | 2026-11-12, America/Detroit |
| Environment | macOS 26.0.1 (build 25A362), Apple silicon (`arm64`), Xcode 26.3 (build 17C529), Apple Swift 6.2.4, project `SWIFT_VERSION = 5.0`, `MACOSX_DEPLOYMENT_TARGET = 14.0` |
| Test target | none. `xcodebuild -list` reports a single `Decelerate` app target and there are no XCTest files, so verification is build plus targeted runtime probes |
| Independent verification | verifier task-9: all 7 round-1 findings confirmed real and the fixes directionally correct; round-2 follow-ups N1-N3 fixed (see "Verification follow-up (round 2)") |

## Scope

All first-party source under `Decelerate/App/`, `Decelerate/Core/` and `Decelerate/UI/`, plus the
behaviour specification (`README.md`), the agent routing table (`docs/agents/codebase-map.md`) and
the verification path (`Scripts/`, `Tools/Probe/`, relevant parts of `Notes/`). Generated trees
(`build/`, `build-ui/`, `dist/`, `Tools/Probe/bin/`, `Tools/Probe/out/`) were treated as output, not
source. The review focused on apply/restore correctness, sleep/wake/device-attach retry logic,
snapshot and corruption handling, retry races, silent error paths, preference persistence,
user-visible state and copy, and docs/behaviour drift.

Out of scope: new features, release/versioning work, building a test target, and re-deriving the HID
mechanism itself (the `Notes/` write-ups were read as the mechanism reference, not re-verified).

## Method

1. Read `AGENTS.md`, `docs/agents/codebase-map.md`, `README.md`, all source files in scope, and the
   apply/restore relevant sections of `Notes/acceleration-research.md` and
   `Notes/acceleration-amount-research.md`.
2. Captured the live pointer state read-only with `python3 Tools/Probe/check-state.py`. This found a
   previously installed Decelerate 1.4.2 running from `~/Applications` (PID 41255, started
   2026-11-09) with per-service user curves active. It was quit gracefully with
   `osascript -e 'tell application id "com.decelerate.app" to quit'` so that controlled runs would
   not fight a second instance; its own restore path was observed in the WindowServer filter log
   (`UserPointerAccelCurvesKey` cleared, `HIDPointerAccelerationAlgorithm:2`, caller
   `AppState.prepareForTermination`) and left the HID parameters unchanged. The user preference
   domain was exported to `/tmp/dec-audit/prefs-backup.plist` before any test that changed
   preferences and re-imported afterwards; the final domain matches the backup.
3. Reviewed the apply, retry, snapshot and restore state machine line by line, then reviewed the
   UI/observable-state layer and the documentation against the code.
4. Ran both build gates (`./Scripts/build.sh` and `./Scripts/build.sh Release`), plus fully clean
   `xcodebuild` builds in temporary derived-data paths so pre-existing warnings could not hide behind
   incremental compilation.
5. Exercised the runtime paths with the repo binary in a controlled way:
   `DECELERATE_DEBUG=1 dist/Decelerate.app/Contents/MacOS/Decelerate --quit-after N`, plus the
   `--restore-defaults`, `--simulate-wake` and `--preview-*` QA paths. Before every run and after
   every run the pointer state was captured with `check-state.py`; `Tools/Probe/filterlog.sh` was
   used as the per-service-curve oracle because `UserPointerAccelCurvesKey` is write-only.
6. Applied the accepted fixes, rebuilt, re-ran the same controls, and confirmed the original pointer
   parameters were restored and no app or probe process was left running.

The repo has no unit-test target; failure-injection cases (rejected parameter write, unavailable
event system, permanently unresolved route) are verified by code inspection because there is no
supported way to force those system states without disturbing the live session. That limitation is
called out per finding.

## Findings

| # | Severity | Confidence | Location (post-fix) | Finding / impact | Fix | Verification / regression evidence |
|---|---|---|---|---|---|---|
| 1 | High | High | `Decelerate/Core/AccelerationController.swift:488-522` | `restoreSystemState()` returned early when the IOHIDSystem parameter connection could not be reopened, so per-service user curves were not cleared. It also discarded the persisted original-value snapshot and last-written marks even when one or more restore writes were rejected. If a restore fails (write/reopen error), the Mac can be left patched with no snapshot left for the next launch to repair it; for a class whose `com.apple.*.scaling` key is absent (the mouse class on this machine) the next launch could then capture the patched value as the "original". | Clear per-service curves through the event-system bridge regardless of the parameter connection, attempt parameter writes only when the connection is available, treat unavailable as failure, and keep `system.accelerationOriginals`/`system.accelerationWrites` unless the restore fully succeeded. Round 2 completed the snapshot guarantee: `write()` now records the value that is actually live when a write is rejected, so a later `captureOriginalsIfNeeded` cannot adopt a scaled index as the user's original. | Code path inspected; normal-run proof: after a successful quit, `defaults read com.decelerate.app` has no `system.*` keys and `check-state.py` shows the original values. Failure-injection itself is not reproducible without a test target (documented limitation); the round-2 rejected-write mark behavior is code-inspected and the normal restore path is re-run below. |
| 2 | Medium | Medium | `Decelerate/Core/AccelerationController.swift:584-596` (callers at `:420`, `:439`, `:460`, `:500`) | `clearOverrides` only wrote the clear for services present in the in-memory `overriddenServices` set. That set does not survive an abnormal exit, and the override property is write-only, so after a crash/force-quit a cached WindowServer user curve could keep shaping the pointer while the next apply (at 100%/Speed 1x) reports macOS's native curve and clears nothing. The property's lifetime after process death could not be observed directly (write-only), which is why confidence is Medium. | Clear the user curve and reset the algorithm on every service in the paths that hand control back (idempotent no-op when no override is installed), and remove the in-memory tracking set that gated it. | Post-fix native-apply log shows `Acceleration key:HIDPointerAccelerationAlgorithm value:2` written by `reapplyAfterEnvironmentChange`/`performApply` on an apply that previously wrote nothing (run with both classes at 100%, Speed 1x). Normal quit still clears curves (filterlog caller `restoreSystemState`). |
| 3 | Medium | High | `Decelerate/Core/AccelerationController.swift:296-330`, `:346-358`; `Decelerate/App/AppState.swift:82-86`, `:206-215` | Retry exhaustion was silent: when a route stayed `.unresolved` for all six attempts, `performApply` returned "needs retry" without an error, the retry loop stopped with only a debug line, and the observable status was never refreshed, so the panel kept showing the settings as applied while macOS stayed in charge. An unavailable full event-system client (`IOHIDEventSystemClientCreate` failure) was also never checked and produced a silent no-op. Failures that happen during asynchronous retries never reached the UI. | Check `bridge.isAvailable` and report it; set a user-facing error when the retry window closes without success; notify the observable layer when a retry series succeeds or is exhausted; have `AppState` refresh its status from the controller in the change callback (which is now invoked after re-apply). | Normal and simulated-wake runs still log `prepareForTermination: restored, error=none` and restore state. The failure path itself is code-inspected only (forcing stale HID enumeration is not safely reproducible); the successful side of the new callback path is exercised by the wake/attach runs. |
| 4 | Medium | High | `Decelerate/App/AppState.swift:217-230`; copy at `Decelerate/UI/SettingsView.swift:90` | "Restore System Defaults" set acceleration to 100% but left the Speed value untouched. Because `performApply` installs a speed-scaled copy of the native curve whenever Speed is not 1x (`AccelerationController.swift:416-426`), the app stayed patched after a "restore": with the shipped default Speed of 1.5x, the macOS curve remained combined with a 1.5x speed curve, while the confirmation dialog promised the pointer settings would be "back the way they were before Decelerate started". | Reset both classes to acceleration 100% and Speed 1x before re-applying, and say so in the dialog copy. | `--restore-defaults --quit-after 7` after starting from 50%/1.5x: debug log shows `apply: trackpad amount=0.5 speed=1.5` on launch, then `restore-defaults: invoking AppState.restoreSystemDefaults`, then `apply: trackpad amount=1.0 speed=1.0`; persisted preferences afterwards are `{"accelerationAmount":1,"speedMultiplier":1}` for both classes, filterlog shows `restoreSystemState` clearing the override, and `check-state.py` shows the original parameters restored. |
| 5 | Low | High | `Decelerate/Core/PointerSettings.swift:106` | A decoded `accelerationAmount` was not range-checked while `speedMultiplier` already was. A corrupt, hand-edited or future-build preference outside 0...1 could reach the sliders and the HID routing checks. | Clamp the decoded amount to 0...1 (same rationale as the existing speed clamp). | Injected `{"accelerationAmount":2.0,"speedMultiplier":1.5}` into `pointer.trackpad`: debug log then reports `apply: trackpad amount=1.0 speed=1.5`, i.e. the clamp took effect; the preference domain was restored from the backup afterwards and `check-state.py` confirms parameters restored. |
| 6 | Low | High | `README.md:27-50` and `:66-70`, `:151`; `Decelerate/UI/SettingsView.swift:191`; `Decelerate/Core/AccelerationController.swift:3-20`; `Decelerate/Core/HIDPointerControl.swift:5-10`; `Decelerate/Core/HIDServiceBridge.swift:32-36`; `Tools/Probe/README.md:8-29`; `Notes/acceleration-amount-research.md:555-570`; `docs/agents/codebase-map.md:92` | Documentation and code comments still described the retired mechanism: 0% was documented as writing the negative IOFixed sentinel / passing raw deltas through, while the shipping code installs a constant-gain user curve and keeps acceleration enabled (and applies the Speed multiplier). The "Speed is inert for table-only mice at intermediate amounts" limitation was undocumented. Two enums also carried dead, duplicated sentinel/fallback constants and an unused `setTable` helper that implied the removed mechanism. | Rewrote the mechanism sections, About copy and class docs; added the table-mouse Speed limitation; appended a "current implementation" correction to the research notes instead of rewriting historical evidence; updated the codebase-map gotcha and line references; removed the dead duplicated constants and unused table-writing helper. | Code/doc cross-check performed for every corrected sentence; full clean Debug and Release builds pass with 0 source warnings. |
| 7 | Low | High | `Decelerate/App/DecelerateApp.swift:53-64`; former call sites at `:137`, `:192` | `SettingsPresenter.activateNow()` passed the `.activateIgnoringOtherApps` option to `NSRunningApplication.activate(options:)`; that option is deprecated in macOS 14 and ignored there, and a fully clean build surfaced it as the only source warning (incremental builds had masked it). `NSApp.activate(ignoringOtherApps:)` is `API_TO_BE_DEPRECATED` rather than deprecated in macOS 14; the two remaining call sites were still using it. | Use `.activateAllWindows` plus `NSApp.activate()` in `activateNow()` (same effective behaviour on macOS 14+), and replace the two remaining `NSApp.activate(ignoringOtherApps:)` call sites with `NSApp.activate()`. | Fully clean Debug and Release builds (`-derivedDataPath` under `/tmp`) report 0 `*.swift` warnings (previously 1); round-2 `./Scripts/build.sh` Debug and Release also pass with 0 `*.swift` warnings. |
| 8 | Low | High | `Decelerate/App/AppState.swift:104-141`, `:218-226`; `Decelerate/UI/Components/StatusBadge.swift:3-9`, `:55-76`; `Decelerate/UI/Components/PointerClassCard.swift:45-59` | At 100% acceleration with Speed != 1× the app installs a speed-scaled copy of the macOS curve (see finding 4), but `isEnabled`, `activeSummary`, the status pill and the pointer-card caption still reported "Off"/"macOS default acceleration": a user with a speed override could see the app as not shaping the pointer while it was. Accepted from verification feedback (round 2; initially deferred as item 3). | Count a non-1× Speed as an active override in `isEnabled`; only report "macOS default acceleration" when amounts are native and speeds are 1×; show "Custom" for speed-only overrides ("1:1 Pointer" now requires linear at 1×); pointer cards say "macOS curve at N× speed" or "linear movement" instead of claiming macOS default. | At 100%/1.5×: panel shows the "Custom" pill and "macOS curve at 1.50× speed" captions; Settings General shows Status "Custom" and Mode "Trackpad 100% · 1.5× · Mouse 100% · 1.5×". The normal 34.7%/1.85× + 50%/1.5× state is unaffected (non-native amounts already produced "Custom"). Screenshots captured in session, not committed. |

Final severity counts after round 2: 1 High, 3 Medium, 4 Low (finding 8 was accepted from verification feedback; it was initially deferred as item 3).

## Verification results

### Build gates

| Gate | Command | Result |
|---|---|---|
| Baseline Debug | `./Scripts/build.sh` at `5348136` | exit 0; only the pre-existing `xcodebuild: WARNING: Using the first of multiple matching destinations` line |
| Baseline Release | `./Scripts/build.sh Release` at `5348136` | exit 0; same destination warning only |
| Debug after fixes | `./Scripts/build.sh` | exit 0; destination warning only, 0 source warnings |
| Release after fixes | `./Scripts/build.sh Release` | exit 0; destination warning only, 0 source warnings |
| Fully clean Debug | `xcodebuild … -configuration Debug -derivedDataPath /tmp/dec-audit/derived-warncheck build` | exit 0; 0 `*.swift` warnings |
| Fully clean Release | `xcodebuild … -configuration Release -derivedDataPath /tmp/dec-audit/derived-release build` | exit 0; 0 `*.swift` warnings |

No new warnings were introduced; the one pre-existing Swift deprecation warning found by the clean
build was fixed (finding 7).

### Controlled runtime checks

All runs used `DECELERATE_DEBUG=1 dist/Decelerate.app/Contents/MacOS/Decelerate …`; no run was left
alive and no probe process was left running.

| Check | Command / action | Result |
|---|---|---|
| Clean baseline | `python3 Tools/Probe/check-state.py` | `HIDTrackpadAcceleration=163840` (2.5), `HIDMouseAcceleration=45056` (0.6875), `HIDPointerAcceleration=45056`, `HIDScrollAcceleration=20480`, `HIDUseLinearScalingMouseAcceleration=0`; defaults `com.apple.trackpad.scaling=2.5`, mouse scaling absent |
| Final apply/quit run | `DECELERATE_DEBUG=1 … --quit-after 6` | trackpad applied via `route=curves` at the user's 34.7%/1.85x, mouse `route=absent` (no mouse attached); stderr ends `prepareForTermination: restoring` → `restored, error=none` |
| State-restore proof | `check-state.py` before/after the final run | `IOHIDSystem.HIDParameters` identical before and after (all five keys, including the untouched scroll parameter and linear-scaling flag); `NSGlobalDomain` pointer defaults identical |
| Snapshot cleanup | `defaults read com.decelerate.app` after the final run | no `system.accelerationOriginals` / `system.accelerationWrites` keys remain; only the user's `pointer.*`, `general.*` and window-frame keys remain |
| Curve clearing on quit | `Tools/Probe/filterlog.sh` after the final run | `Acceleration key:UserPointerAccelCurvesKey value:(` clear, then `Acceleration key:HIDPointerAccelerationAlgorithm value:2 … caller: …AccelerationController.restoreSystemState`, then `Pointer acceleration (enabled) HIDTrackpadAcceleration:163840` |
| Restore System Defaults | `… --restore-defaults --quit-after 7` (from 50%/1.5x) | launch applies `amount=0.5 speed=1.5`; at 2 s the action runs; re-apply logs `amount=1.0 speed=1.0`; persisted prefs become `{"accelerationAmount":1,"speedMultiplier":1}`; filterlog shows the override cleared by `restoreSystemState` |
| Preference clamp | injected `accelerationAmount=2.0` for the trackpad, `… --quit-after 3` | debug log reports `apply: trackpad amount=1.0`; parameters restored after quit; preference domain restored from backup afterwards |
| Wake re-apply | `… --simulate-wake --quit-after 6` | log shows `environment: NSWorkspaceDidWakeNotification`, HID clients refreshed, both classes re-applied, `restored, error=none`; `check-state.py` before/after identical |
| UI smoke | `… --preview-panel --quit-after 3` and `… --preview-settings --quit-after 3` | both exit 0; stderr shows only the restore lines (`restored, error=none`), no crash/error; state restored |
| No leftovers | `pgrep -fl Decelerate`, `pgrep hidprobe` | no Decelerate, hidprobe or tapmeasure process left running |
| User data | `defaults export com.decelerate.app -` vs `/tmp/dec-audit/prefs-backup.plist` | preference domain restored to the pre-audit content after the tests |

Note on the state-restore proof: `check-state.py` reads the HID parameter dictionary, service
mirrors and defaults; per-service `UserPointerAccelCurvesKey` overrides are write-only and cannot be
read back (`HIDServiceBridge.swift:192-197`), so the curve-clear half of the restore is evidenced by
the WindowServer filter log, and the parameter half by `check-state.py`. Both are shown above.

### Limitations

- No test target exists; the repo's own contract is build + manual run + probes, and the audit did
  not add test infrastructure.
- Failure-injection paths (finding 1 and 3's failure branches) are verified by code inspection only;
  forcing a rejected `IOHIDSetCFTypeParameter` or a permanently stale event-system enumeration
  without a second machine/hardware is not safe or reproducible.
- No external mouse was attached, so the table-only mouse index-scaling route and the "Speed inert at
  intermediate amounts" path could not be exercised end-to-end; the built-in trackpad's parametric
  curve route and the absent-class path were exercised.
- The lifetime of a per-service user curve after the writing process is killed could not be observed
  directly (write-only property); finding 2 is therefore an idempotent safety hardening, with
  confidence Medium.

## Verification follow-up (round 2)

An independent verifier (task-9) re-checked the round-1 branch: all seven findings were confirmed
real and the fixes directionally correct, the build/state gates reproduced, and three residual items
(N1-N3 below) were requested. All three were accepted and are fixed in the round-2 code commit
`3c71b721dfdd9f1bd4dae9b38a0c7eaae2844364`; report and map corrections are in the follow-up docs
commit. N3 was promoted from deferred item 3 to finding 8.

### N1 (Medium): the finding-1 snapshot-retention fix was incomplete

`write()` recorded `lastWritten = requestedValue` *before* attempting the write. After a rejected
restore write for a table-only class, the live value stays the scaled value S while the mark claims
the original O; the next launch's `captureOriginalsIfNeeded` sees `lastWritten != live` and adopts S
as the original, so the retained snapshot is still unusable and the index scaling compounds on every
relaunch. Fix: `write()` now reads the live value first, writes only when it differs, records the
requested value on success, and records the live value on a rejected write (keeping the previous mark
if even the read fails). A later capture therefore either skips the value because it equals the mark,
or reads a value that is genuinely external/user-owned. The restore comment that overstated what the
marks alone guaranteed was corrected. Evidence: code inspection (the rejected-write path cannot be
forced without injecting I/O failures and there is no test target); the normal write/read path and
restore were re-run in the controlled run below.

### N2 (Low): restore lacked performApply's event-system availability guard

`restoreSystemState()` now starts with `rejected = !bridge.isAvailable`, matching the guard in
`performApply`. A nil full event-system client makes `pointerServices()` empty, so without this a
restore could clear the snapshot and report success while a cached user curve survived. Evidence:
code inspection; the normal restore path in the controlled run is unchanged (`restored, error=none`
plus the filterlog curve clear).

### N3 (Low): status model claimed "Off" while a speed-scaled curve was installed

Accepted. At 100% acceleration with Speed != 1× the app installs a speed-scaled copy of the macOS
curve, so this is an active override. `isEnabled` now also counts a non-1× Speed; `activeSummary`
only says "macOS default acceleration" when amounts are native and speeds are 1×; the status pill
reports "Custom" for speed-only overrides (the "1:1 Pointer" label now requires linear at 1×); and
the pointer cards say "macOS curve at N× speed" (or "linear movement" at 0% with a non-1× speed)
instead of "macOS default acceleration". Evidence: at 100%/1.5× the panel and Settings General were
captured with `swift Scripts/windowshot.swift` during `--preview-panel`/`--preview-settings` runs;
they show the "Custom" pill, "macOS curve at 1.50× speed" captions, and Mode
"Trackpad 100% · 1.5× · Mouse 100% · 1.5×". The user's normal 34.7%/1.85× + 50%/1.5× state is
unaffected because non-native amounts already produced "Custom".

### Report corrections applied

- Finding 1 no longer claims the last-written marks alone protect the snapshot; the `write()` live
  value mark above is what makes the retained snapshot reliable.
- Finding 7 now distinguishes the macOS-14 deprecation of the `.activateIgnoringOtherApps` option
  from the `API_TO_BE_DEPRECATED` `NSApp.activate(ignoringOtherApps:)`, notes the two remaining call
  sites at `DecelerateApp.swift:137`/`:192`, and records that they were replaced as part of round 2.
- Removed the `appintentsmetadataprocessor` tool-message note: it did not reproduce in the
  verifier's clean builds, so it is not reported as a fact.
- `docs/agents/codebase-map.md` "Verified against" now points at the round-2 code commit
  `3c71b72…`, and its changed line references were re-checked against the final tree.

### Round-2 final verification

| Check | Result |
|---|---|
| Debug gate | `./Scripts/build.sh` exit 0, 0 `*.swift` warnings |
| Release gate | `./Scripts/build.sh Release` exit 0, 0 `*.swift` warnings |
| Controlled run | `DECELERATE_DEBUG=1 dist/Decelerate.app/Contents/MacOS/Decelerate --quit-after 5` exit 0; stderr ends `prepareForTermination: restored, error=none`; `check-state.py` before/after shows identical `IOHIDSystem.HIDParameters` (trackpad 163840, mouse/pointer 45056, scroll 20480) and identical pointer defaults; no `system.acceleration*` preferences remain; filterlog shows the `UserPointerAccelCurvesKey` clear and `HIDPointerAccelerationAlgorithm:2` with caller `AppState.prepareForTermination`, then native `HIDTrackpadAcceleration:163840` |
| Installed app | the verifier had relaunched the installed app; it was quit again for the single-instance controlled run, then relaunched with `open ~/Applications/Decelerate.app` and left running (its own restore keeps the HID parameters at the values above) |
| UI state | panel + Settings screenshots at 100%/1.5× (see N3); default user state unchanged |

## Deferred items

1. `restoreSystemState()` enumerates services once. If the event system transiently returned no
   services at quit, a previously installed curve on a service that still existed could be missed;
   a bounded re-enumeration retry was considered but not implemented because it could not be
   reproduced and the write-only property gives no way to confirm a miss.
2. Table-only (third-party) mouse hardware was not available for testing. The index-scaling route and
   the multi-entry vendor-table approximation remain research-limited (see
   `Notes/acceleration-amount-research.md` §6/§11 and the "no external mouse" limitation in
   `Tools/Probe/README.md`).
3. Dead-but-documented diagnostics/API stubs were left alone: `needsPermission`,
   `refreshPermissionStatus()`, `requestPermissionIfNeeded()`, `serviceSummary`,
   `Status.isActive`, `setAccelerationAmount(ForAll:)` and `PreferencesStore.onboardingDone` have no
   call sites but are either explicitly retained for API stability or harmless diagnostics; removing
   them was not worth the churn in this audit.
4. `HIDPointerControl` never unregisters its property-change callbacks before deinit; the client is
   released and unscheduled first, and no issue was observed. Left as is.
5. `Tools/Probe/PointerAccelerationController.swift` remains the historical reference implementation;
   it was annotated in `Tools/Probe/README.md` rather than rewritten, because it is research evidence
   and is still used as a compile-time reference.
6. The historical sections of `Notes/acceleration-research.md` / `Notes/acceleration-amount-research.md`
   that describe the negative sentinel were kept as written research history; the current behaviour
   is recorded in a new correction section (§13) at the end of the amount notes.
7. The verifier's clean builds did not reproduce the `appintentsmetadataprocessor` message seen once in
   this environment, so no build-tool warning is claimed; only Swift warnings are reported above.

## Notes

Files changed across both rounds (12 distinct files, 11 modified plus this new report; round 2 touched 5 of them):

- `Decelerate/Core/AccelerationController.swift`: restore snapshot retention and curve clearing
  without the parameter connection (finding 1); unconditional override clearing and removal of the
  in-memory tracking set (finding 2); retry-exhaustion/unavailable-event-system reporting and
  observable-state notifications (finding 3); corrected mechanism doc comment (finding 6); round 2:
  `write()` records the live value on a rejected write (N1) and restore gained the event-system
  availability guard (N2).
- `Decelerate/App/AppState.swift`: `refreshStatus()` used by `reapply` and by controller change
  callbacks (finding 3); Restore System Defaults resets Speed to 1x (finding 4); round 2: the status
  model counts a non-1x Speed as an active override (finding 8).
- `Decelerate/UI/Components/StatusBadge.swift`: round 2: status pill logic for speed-only overrides
  (finding 8).
- `Decelerate/UI/Components/PointerClassCard.swift`: round 2: accurate captions at 100% with a
  non-1x Speed and 0% with a non-1x Speed, and corrected 1.5x-middle comments (finding 8).
- `Decelerate/App/DecelerateApp.swift`: Restore System Defaults QA hook `--restore-defaults`
  (verification for finding 4); deprecated activation API replaced (finding 7); round 2: the two
  remaining `NSApp.activate(ignoringOtherApps:)` call sites replaced (finding 7 follow-up).
- `Decelerate/Core/PointerSettings.swift`: clamp decoded acceleration amount (finding 5).
- `Decelerate/Core/HIDPointerControl.swift`: removed dead sentinel/key duplicates; corrected doc
  comment (finding 6).
- `Decelerate/Core/HIDServiceBridge.swift`: removed dead duplicated sentinel/fallback constants and
  unused `setTable` helper (finding 6).
- `Decelerate/UI/SettingsView.swift`: About copy and Restore defaults dialog copy (findings 4, 6).
- `README.md`: current 0% mechanism, table-mouse Speed limitation, `--restore-defaults` flag
  (findings 6, 4).
- `Notes/acceleration-amount-research.md`: §13 correction for the current 0% / Speed / 100%
  implementation (finding 6).
- `Tools/Probe/README.md`: historical status of the reference controller (finding 6).
- `docs/agents/codebase-map.md`: gotcha and changed-line references updated (finding 6).
- `docs/audits/2026-11-12-code-quality-audit.md`: this report.

Operational notes:

- A previously installed Decelerate 1.4.2 instance was running when the audit started. It was quit
  gracefully (which restored its own state) so controlled runs would be deterministic. During round 2
  the verifier had relaunched it; it was quit again for the single-instance controlled run and then
  relaunched with `open ~/Applications/Decelerate.app`, so it is running at the end of round 2 as
  requested, with the HID parameters at their original values.
- The user preference domain was backed up before the tests that changed it (clamp injection and the
  restore-defaults runs) and restored afterwards; the final domain matches the backup.
- No version bump, tag, release, push or git remote operation was performed by this audit; fixes and
  this report are local commits on `main` only.
