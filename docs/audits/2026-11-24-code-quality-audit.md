# decelerate — code-quality and security audit (2026-11-24)

> **Status: report only.** No file in this repository was modified. Every finding carries a
> proposed fix for review; no regression test was added and no version file was touched.
> No test target exists; Debug and Release builds pass. Verification path is build + manual run + Probe.

## Baseline

| | |
|---|---|
| Repository | `/Users/etm1air/Files/Github/decelerate` |
| Commit | `52725fd` on `main` ("docs: bump codebase-map verification commit after 1.5.0"); working tree clean at audit start (`git status --short` empty) |
| Build | `./Scripts/build.sh` → exit 0, 7.5 s, stages `dist/Decelerate.app` (Debug). `./Scripts/build.sh Release` → exit 0. Both emit only `xcodebuild: WARNING: Using the first of multiple matching destinations`; 0 `warning:` lines, no `*.swift` warnings |
| Test target | **None.** `xcodebuild -list -project Decelerate.xcodeproj` reports one target (`Decelerate`), two configurations, one scheme, and there are no XCTest files. There is no suite, no coverage, and nothing in this report is backed by a test run |
| Project settings | `MACOSX_DEPLOYMENT_TARGET = 14.0`, `SWIFT_VERSION = 5.0`, `ENABLE_APP_SANDBOX = NO`, `ENABLE_HARDENED_RUNTIME = NO`, `CODE_SIGN_IDENTITY = "-"`, `GENERATE_INFOPLIST_FILE = YES`, `INFOPLIST_KEY_LSUIElement = YES` (`Decelerate.xcodeproj/project.pbxproj:257-268`, `:286-297`). No `.entitlements` file exists in the tree. Debug uses `-Onone`/`ENABLE_TESTABILITY = YES`; Release uses the default `-O` |
| LOC in scope | 3,878 Swift lines (`Decelerate/App` + `Core` + `UI`, 18 files); 903 Swift lines in `Tools/Probe`; 964 Python lines in `Tools/Probe`; 127 lines of shell/Swift in `Scripts/`; `Tools/Probe/TCCProbe/main.c` (~55 lines). ≈5.9k |
| Live session | The installed copy (`~/Applications/Decelerate.app`, PID 83025) was already running with the user's settings (trackpad 29.7 % / 1.501×, mouse 20.2 % / 1.503×, mouse scroll 0 % / 1.489×) and per-service curves attached (`verify-applied.py`: `trackpad pointer-curves=yes scroll-curves=yes`). `IOHIDSystem` parameters at audit time: trackpad 163840 (2.5), mouse/pointer 45056 (0.6875), all three scroll keys 20480 (0.3125). This audit **did not launch or quit the app**; no HID writing path was exercised except the no-op re-write described under DC-06

Verification for this repo is build + manual run + the Probe tools. No test target exists, so the findings below rest on code traces, the repo's own research notes, and throwaway probes under `/tmp/code-audit/probes/`; they are not regression-tested.

## Scope and method

Read in full, in this order:

- `AGENTS.md`, `docs/agents/codebase-map.md` (its `Don't read` set was respected: no `build/`, `build-ui/`, `dist/`, `Tools/Probe/bin/`, `Tools/Probe/out/`, `docs/` PNGs, `.git/`), `README.md`, the prior audit `docs/audits/2026-11-12-code-quality-audit.md`.
- `Notes/acceleration-amount-research.md` §2.3, §3, §4, §5, §7, §11, §12, §13 and `Notes/acceleration-research.md` §3, §5.1, §5.2 (the physics/API contract, skimmed as instructed).
- Every source file in scope: all 18 Swift files under `Decelerate/`, `Tools/Probe/hidprobe.swift`, `tapmeasure.swift`, `PointerAccelerationController.swift`, `check-state.py`, `curve_math.py`, `verify-applied.py`, `filterlog.sh`, `build.sh`, `tcc-test.sh`, `TCCProbe/main.c`, `Scripts/build.sh`, `install.sh`, `windowshot.swift`, `generate-icon.py`, the `.pbxproj` build settings that matter (deployment target, sandbox, hardened runtime, signing, optimization, Info.plist generation).

Probes written and run (nothing outside `/tmp/code-audit/probes/`, no repo file touched):

| Probe | Purpose | Result used in |
|---|---|---|
| `trap.swift` | Reproduce the `Int32((v * 65536).rounded())` conversion from `AccelerationController.swift:203` | DC-03 |
| `perf5.swift` | Time `IOHIDEventSystemClientCreate` (what `HIDServiceBridge.refresh()` does) | DC-02 |
| `perf3.swift` / `perf.swift` | Separate client-create cost from `CopyServices`/`conformsTo`/property reads; fd growth over 300 create/destroy cycles; `IOHIDCopyCFTypeParameter` / `IOHIDSetCFTypeParameter` cost | DC-02, DC-06, "Checked and clean" |
| `perf4.swift` | Spaced write latency (10 writes of the *current* value, re-read afterwards: 163840 before and after) | DC-06 |
| `curvecompare/main.swift` + `curvecompare/CurveBuilder.swift` (copy of the repo file) | Run the shipped `AccelerationCurveBuilder` against the coefficients `curve_math.py` generates | DC-04 |
| `invert.swift` (output `invert.out`) | Evaluate the filter's parametric gain for the curve produced by `negated()` | DC-01 |
| `decodeprobe/main.swift` + `decodeprobe/PointerSettings.swift` (copy) | Decode matrix for `CategoryPreferences` | DC-12 |

The `IOHIDSystem` parameter probes only read, except `perf4.swift`/`perf.swift`, which re-wrote the value that was already live (`HIDTrackpadAcceleration = 163840`, verified unchanged afterwards) in order to measure the write path. `verify-applied.py` and `check-state.py` were run read-only for the live baseline. No system setting, device, or app state was changed.

**What this audit did not do, and why:** it did not run the app. Launching it would immediately replace the user's live curve set with the persisted 29.7 %/1.5× state and would require trusting the quit-restore path to put the session back; the repo's own contract is that this is verified by a human on real hardware, and every finding below is derivable without it. The runtime checks that remain are listed at the end. Also out of scope by instruction: style/naming, the HID mechanism research itself, and any file under the excluded build trees.

## Findings

### DC-01 — "Invert scroll direction" cannot invert a blended scroll curve, and silently drops the Scroll-acceleration amount on table-only mice

- **Severity:** High
- **Confidence:** High
- **Class:** correctness
- **Location:** `Decelerate/Core/AccelerationController.swift:1012`, `:1058`, `:1088`, `:993`
- **Code:**
```swift
            if hasCurves {
                if !installBlendedScrollCurves(amount, speed: speed, invert: invert, on: classServices) {
                    rejected = true
                    needsRetry = true
                }
            } else if !installConstantScrollCurves(speed: speed, invert: invert, on: classServices) {
```
```swift
    private static func negated(_ curves: [[String: Int]]) -> [[String: Int]] {
        curves.map { curve in
            var flipped = curve
            for key in [
                HIDCurveKey.gainLinear, HIDCurveKey.gainParabolic,
                HIDCurveKey.gainCubic, HIDCurveKey.gainQuartic,
            ] {
                if let gain = flipped[key] {
                    flipped[key] = -gain
                }
```
- **Defect:** two distinct paths are wrong.

  (a) For a service that exposes `HIDScrollAccelCurves`, `installBlendedScrollCurves` blends the native curve and then negates every gain coefficient. The filter's first segment is `f1(v) = GL·v + (GP·v)² + (GC·v)³ + (GQ·v)⁴` (`Tools/Probe/curve_math.py:23-25`, `Notes/acceleration-amount-research.md` §3), so negating `GP`/`GC`/`GQ` flips only the odd powers: the **quadratic term keeps its sign** and takes over as soon as `(GP·v)²` exceeds `|GL·v|`. The result is a curve that points the wrong way only for extremely slow movement and the original way above the crossover. Above `TSPR` it is worse: the third segment is `sqrt(m1·v + b1)`, which cannot be negative at all, so the tail is unconditionally in the original direction. Trigger: the mouse class with `Invert scroll direction` on and `Scroll` acceleration at any value above 0.5 % (the default 100 % included) on a device whose service carries `HIDScrollAccelCurves` (the route doc comment at `Decelerate/Core/AccelerationController.swift:856` says "Parametric curves exist on Apple trackpads (and some Apple mice)", and `HIDServiceBridge.swift:33-35` says plain USB mice fall back to the default table, so both kinds exist).

  (b) For a service **without** scroll curves, `useCurves` is true merely because `invert` is set (`:993`), and the `else` branch installs a constant-gain curve from `speed` alone. `amount` is never used, so with Invert on the Scroll-acceleration slider is inert while the card still prints `Blended scroll 50%` (`Decelerate/UI/Components/PointerClassCard.swift:81`). Trigger: any table-only (third-party) mouse, Invert on, any Scroll value below 100 %.
- **Impact:** for the device population that actually gets the Invert toggle, the feature either does nothing (fast/normal scrolling keeps its direction) or reverses only at a crawl — a user reports "invert is broken". On table-only mice the same toggle silently disables the Scroll-acceleration slider. Users lose the scroll-blend control without any UI change.
- **Proposed fix:** never negate a curve that has a `sqrt` tail or even-order terms. When `invert` is set, install a constant negative-gain curve (as the table path already does): `GL = -speed`, `GP = GC = GQ = 0`, `TSL = TSPR = 0` — and disable or relabel the Scroll amount slider while inverted, or reject a blended inversion with an explicit error. If a shaped inversion is really wanted, emit only `GL` and `GC` negative with `GP = GQ = 0` and `TSPR = 0`, which is provably negative for all `v > 0`.
- **Evidence:** `/tmp/code-audit/probes/invert.swift` evaluates the filter's gain for the negated native trackpad curve (`GL=-0.86, GP=-1.45, GC=-0.24, TSL=7, TSPR=14`): gain is negative only below `v_std = 0.4101`, then `+1.76` at `v=1`, `+4.71` at `v=2`, `+18.88` at `v=7`, `+37.06` at `v=14`, `+13.95` at `v=20`. The repo's own conversion (`Notes` §7: `v_std 2 ≈ 3.6 in/s`) puts the crossover at ≈0.7 in/s of finger speed. The constant inverted curve is exact by construction (the table-only path, and the `amount = 0` case on curve devices, which is the only configuration that works).

### DC-02 — the 2 s applied-state watchdog blocks the main thread for ~100 ms per tick

- **Severity:** High
- **Confidence:** High
- **Class:** performance
- **Location:** `Decelerate/Core/AccelerationController.swift:511-516`, `:551-557`, `:366-372`
- **Code:**
```swift
        // Always look through a freshly created connection. A long-lived
        // IOHIDEventSystemClient does not reliably report services macOS
        // created after it connected, and "the client cannot see the new
        // service" is exactly how a reverted pointer stays unnoticed. The
        // connection is cheap to create and nothing else depends on holding it.
        bridge.refresh()
        let live = bridge.pointerServiceFingerprint()
        guard live != appliedFingerprint else { return }
```
- **Defect:** `refresh()` (`Decelerate/Core/HIDServiceBridge.swift:148`) is `client = clientFactory?(kCFAllocatorDefault)`, i.e. `IOHIDEventSystemClientCreate` — not cheap. Measured p50 **99.5 ms** (min 90.3, max 115.2) in one run and p50 **92.5 ms** (min 90.6, max 134.7) in a second, n=25 each, in a plain CLI process in the same session; the actual fingerprint work (`CopyServices` + 3 `IOHIDServiceClientConformsTo` + `registryID` over all 141 services) is **0.008 ms**. The `Timer` is added to `RunLoop.main` (`:515`), so `verifyAppliedServices` and its 100 ms refresh run on the main thread, forever, whenever `isShaping` is true — which is the default 50 %/1.5× configuration. The same refresh is also on the `didBecomeActiveNotification` path (`:366-372`), so opening Settings (`SettingsPresenter.present` → `NSApp.activate()`) pays it again, and `systemParameterChanged` pays it on every external HID parameter change (`:1274`).
- **Impact:** an ~100 ms main-thread stall twice a second (a 5 % duty cycle on one core) while the app is shaping anything. In practice: hitching in the menu bar panel and Settings while the user drags sliders or opens the panel, extra wakeups and battery drain on a utility that is supposed to be invisible, and a stall exactly at the moment the user opens the UI to check the status. The pointer itself is unaffected (nothing is intercepted).
- **Proposed fix:** stop recreating the client per tick. Keep a long-lived client for the fingerprint and invalidate it on the events that actually replace services (wake, attach, `heal`), or keep a cheap change signal (e.g. `IOServiceGetMatchingServices` on `AppleMultitouchDevice`/pointer services) and only call `refresh()` when the cheap signal moves. The "do not cache a `HIDPointerService` across applies" rule in the map is about the *service refs used for writes*, not about holding a client for a registry-ID poll, so a retained poll client does not violate it. If the refresh must stay per tick, do it off the main actor and hop back with the resulting set.
- **Evidence:** `/tmp/code-audit/probes/perf5.swift` (run 1: `min 90.3 p50 99.5 p90 107.3 max 115.2 ms`; run 2 in `perf5.out`: `min 90.6 p50 92.5 p90 100.9 max 134.7 ms`, the max being the first call), `/tmp/code-audit/probes/perf3.swift` (`create + CopyServices` 96.977 ms/call vs `conformsTo x3 + registryID over all services` 0.008 ms/call), `/tmp/code-audit/probes/perf.swift` (0 fd growth over 300 client create/destroy cycles, so this is latency, not a handle leak).

### DC-03 — `Int32` conversion trap on `com.apple.*.scaling` makes the app crash on every launch

- **Severity:** High
- **Confidence:** High
- **Class:** security
- **Location:** `Decelerate/Core/AccelerationController.swift:196-204` (called from `init` at `:158`); same pattern in `Tools/Probe/hidprobe.swift:262`
- **Code:**
```swift
    private static func macOSSettingRaw(forKey key: String) -> Int32? {
        let defaultsKey = key == HIDPropertyKey.trackpadAcceleration
            ? "com.apple.trackpad.scaling"
            : "com.apple.mouse.scaling"
        guard let number = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber else {
            return nil
        }
        let raw = Int32((number.doubleValue * 65_536.0).rounded())
```
- **Defect:** Swift's `Int32(Double)` is a trapping conversion. Any value of `com.apple.trackpad.scaling` / `com.apple.mouse.scaling` whose `doubleValue × 65536` does not fit in `Int32` (i.e. `|v| > 32767.99`, plus NaN/±inf) traps with "Double value cannot be converted to Int32". The range check (`isPlausibleOriginal`, 8192…196608) happens *after* the conversion, so it cannot protect it. These are ordinary global-domain user defaults — any script, installer, managed-preferences profile, backup restore, or earlier buggy build can write them. `AccelerationController.init` runs for `managedKeys` (three keys) during `AppState.init`, before the first window is shown, and the offending value survives, so the app is unlaunchable until someone removes the default. The same unchecked conversion exists in `Tools/Probe/hidprobe.swift:262` (`Int32(d * 65536.0)` in `makeValue`), reachable with `hidprobe param-set … fixed:1e6`, and the probe README tells users to type `fixed:-1` values by hand.
- **Impact:** crash loop at launch with no in-app recovery ("double-click → crash"); on the probe side a CLI crash instead of "bad value". Because the app is the only convenient way to repair its own HID writes, a user whose mouse parameters were index-scaled keeps that state until logout/reboot or a manual repair.
- **Proposed fix:** validate before converting: `guard number.doubleValue.isFinite, abs(number.doubleValue) <= 3.0 else { return nil }` (3.0 is the documented upper end of the useful range, matching `isPlausibleOriginal`'s 196608 cap), then convert. In `hidprobe`, clamp and print "bad value" instead of trapping. A unit test with an injected `UserDefaults` (see gaps) would pin this.
- **Evidence:** `/tmp/code-audit/probes/trap.swift` reproduces the exact expression: `2.5 → 163840` (exit 0), `40000 → SIGTRAP` (shell exit 133), `1e300 → SIGTRAP` (exit 133).

### DC-04 — `curve_math.py` still generates the retracted `1/kCursorScale` identity, and Notes §11 still cites it

- **Severity:** Medium
- **Confidence:** High
- **Class:** correctness
- **Location:** `Tools/Probe/curve_math.py:16-19`, `:163-168`; `Notes/acceleration-amount-research.md:493-500`; `:519-528`
- **Code:**
```python
  * therefore the parametric curve S(v) produces gain g(v) = kCursorScale * S(v)/v,
    and a true 1:1 curve needs GainLinear = 1/kCursorScale = 67/96 (not 1.0!).
```
```python
    if f <= 0:
        return dict(Index=0, GL=1.0 / KC, GP=0.0, GC=0.0, GQ=0.0, TSL=0.0, TSPR=0.0)
    # (four lines elided)
    root = {"GL": (1 - f) / KC + f * native["GL"],
```
- **Defect:** the executable model that `docs/agents/codebase-map.md` names as the curve reference ("Curve blend and speed math … source-derived model in `Tools/Probe/curve_math.py`") implements the formula the notes later retract. `Notes` §12 says: "The §4 `kCursorScale` correction is wrong, and was reverted in 1.2 … so `GL = 1.0` is the identity, not `1/kCursorScale`. … Using `1/kCursorScale` made every low-amount setting ~30% slower than 1:1." The shipped builder implements the corrected `GL_f = 1 + f·(GL − 1)` (`Decelerate/Core/AccelerationCurveBuilder.swift:78-81`), but `curve_math.py` still emits `GL_f = (1−f)/KC + f·GL` and still asserts in its docstring that `GL = 1/KC` is the identity; `Notes` §11 (the 1.1 implementation note) still says the shipped coefficients "come from the §4 corrected formula (`GL' = (1−f)/kCursorScale + f·GL_n`) … verified", and §7's "expected serialized output" table (GL = 45739 / 48394 / 51050 / 53705) is that retracted curve.
- **Impact:** no effect at runtime today, but the model is the thing an engineer will regenerate the blend table from. Its numbers differ from the shipping builder by exactly `(1−f)·(1−1/KC)`: at f = 0 GL 0.69792 vs 1.00000, f = 0.25 0.73843 vs 0.96500, f = 0.5 0.77896 vs 0.93001 (f = 1 agrees). Anyone "fixing" the builder to match the model re-introduces the 1.2 regression the notes describe (~30 % slower than 1:1 at low amounts), and `verify-applied`/curve-fit work built on the model will validate the wrong curve.
- **Proposed fix:** make `identity()`/`blend()` model the shipped formula, or add an unmistakable header to `curve_math.py` ("superseded by Notes §12; not the shipping formula") and fix its docstring line, regenerate the §7 table from the shipped builder, and mark §11 as historical like §13 already is.
- **Evidence:** `/tmp/code-audit/probes/curvecompare/` (output in `curvecompare.out`) prints both coefficient sets per f (0, 0.006, 0.05, 0.25, 0.5, 0.75, 0.995, 1.0); the builder's `GL` values match `1+f(GL_n−1)` exactly and the model's match `(1−f)/KC+f·GL_n`. Section numbers and quotes re-read at `Notes/acceleration-amount-research.md:519-528` and `:493-500`.

### DC-05 — README still says scroll acceleration is untouched while the app shapes it

- **Severity:** Medium
- **Confidence:** High
- **Class:** correctness
- **Location:** `README.md:71`, `Decelerate/UI/Components/PointerClassCard.swift:212`, `:244`, `Decelerate/Core/AccelerationController.swift:946`
- **Code:**
```
- Scroll acceleration is untouched. It is a separate HID parameter.
```
```swift
                    Slider(value: state.binding(for: pointerClass).scrollAccelerationAmount, in: 0...1)
                    // (scroll-speed slider elided)
                    Toggle("Invert scroll direction", isOn: state.binding(for: pointerClass).invertScroll)
```
- **Defect:** the 1.5.0 feature set added per-class scroll shaping — two sliders and an invert toggle per class, `UserScrollAccelCurvesKey` writes, and `HIDTrackpadScrollAcceleration`/`HIDMouseScrollAcceleration` writes (`applyScroll`, `:946-1044`). The README's behaviour section still states scroll is untouched, and its `## Usage` list documents only Acceleration and Speed, not the Scroll controls that the shipped panel shows. The About tab (`Decelerate/UI/SettingsView.swift:183`, `:191`) does describe scroll shaping, so the two documents disagree with each other.
- **Impact:** the app's own documentation tells users their scroll behaviour will not change and does not mention the controls that change it; when scroll behaviour does change (or when a user cannot find the setting that caused it), the README is actively wrong. It also hides the DC-01 limitations from users.
- **Proposed fix:** replace the line with a short description of the Scroll controls (amount, speed, invert) and add them to `## Usage`; state the two limitations from DC-01. The docs already claim parity with the shipped UI elsewhere (`docs/panel.png` shows the scroll controls), so this is a one-paragraph edit.
- **Evidence:** code trace of `applyScroll` and the card's scroll section; README read at `:65-75` and `## Usage` at `:112-127`.

### DC-06 — parameter writes cost ~10 ms each and the table path performs two of them per slider tick, on the main thread

- **Severity:** Medium
- **Confidence:** High
- **Class:** performance
- **Location:** `Decelerate/Core/AccelerationController.swift:1172-1195`, `:1200-1210`, `:1132-1140`
- **Code:**
```swift
        let live = parameters.readRaw(key)
        if live == raw {
            lastWritten[key] = raw
            persistWrites()
            return true
        }
        let wrote = parameters.writeRaw(key, raw)
```
```swift
        let scaled = max(1, Int32((Double(base) * amount).rounded()))
        // Scaling can only reduce the index, never raise it.
        return write(key, min(scaled, base))
```
```swift
        if wrote {
            lastWritten[key] = raw
        } else if let live {
            lastWritten[key] = live
        }
        persistWrites()
```
- **Defect:** `IOHIDSetCFTypeParameter` measured **9.7 ms median** (8.8–14.3 ms) in one run and **21.2 ms median** (9.0–35.2 ms) in a second (n=10 each, 150 ms apart); it is a synchronous kernel call made on the main actor; back-to-back writes measured **55.8 ms/call**, i.e. consecutive writes are ~5.7× more expensive than spaced ones (the notification/rebuild work serialises). The measured write re-used the value that was already live, so this is the call-plus-notification cost of the same `IOHIDSetCFTypeParameter` the app makes when a value changes. The index-scaling route calls `writeScaled` for **both** mouse keys on every apply (`parameterKeys(for: .mouse)` = `HIDMouseAcceleration` + `HIDPointerAcceleration`), so each drag tick that *changes the amount* on a table-only mouse blocks ~20–40 ms (a Speed-only change computes the same scaled value, so `write()` early-outs and only the apply + defaults work remains). `write()` additionally runs `persistWrites()` (JSON encode + `UserDefaults.set`) on *every* key, including the no-op path, and `performApply` adds two more persists (`persistOriginals`, `persistScrollOriginals`). Restore on quit writes six parameter keys (~60 ms), each followed by its own `UserDefaults` write plus four more at the end, all in `applicationWillTerminate`. The curves route is cheaper only by accident: its parameter write is skipped because the value is already live (`write()` early-out at `:1176`), so the 10–20 ms only appears when a value genuinely changes.
- **Impact:** with a third-party mouse, dragging the Acceleration or Scroll slider hitches or drops frames (each amount change ~20–40 ms of main-thread blocking plus six defaults writes); dragging Speed still runs a full apply per tick, and quitting or restoring shows a ~60 ms stall. The user perceives the sliders as sluggish precisely for the device class whose Speed control the README already says is limited.
- **Proposed fix:** coalesce applies while a slider is being dragged (apply on drag-end, or throttle `reapply()` to ~30 Hz), batch the four `persist*` calls into one defaults write per apply, and skip `persistWrites()` on the no-op path. Restore can keep its writes but should do them in one pass without the per-key persists.
- **Evidence:** `/tmp/code-audit/probes/perf4.swift` (spaced writes of the live value, median 9.7 ms in run 1 and 21.2 ms in run 2, value unchanged 163840 → 163840; `perf4.out`), `/tmp/code-audit/probes/perf.swift` (200 back-to-back writes: 55.8 ms/call; `IOHIDCopyCFTypeParameter` 54.6 µs/read).

### DC-07 — route selection is per class, so one table-only mouse downgrades a curve-based mouse in the same class

- **Severity:** Medium
- **Confidence:** Medium
- **Class:** correctness
- **Location:** `Decelerate/Core/AccelerationController.swift:861-869`, `:740-761`
- **Code:**
```swift
    private static func route(for services: [HIDPointerService]) -> Route {
        guard !services.isEmpty else { return .absent }
        if services.allSatisfy({ $0.hasNativeCurves }) { return .curves }
        let tableOnly = services.filter { !$0.hasNativeCurves }
        if tableOnly.allSatisfy({ $0.hasAccelerationTable }) { return .indexScaling }
        return .unresolved
    }
```
- **Defect:** `.curves` requires **every** service of the class to expose `HIDAccelCurves`. If one attached mouse is table-only, the whole class falls to `.indexScaling`, and `performApply` then index-scales the shared `HIDMouseAcceleration`/`HIDPointerAcceleration` and calls `clearOverrides(on: classServices)` — which clears the user curve and sets `HIDPointerAccelerationAlgorithm = 2` on the *curve-capable* mouse too. That device then selects a native curve entry by the scaled index instead of getting the blend, and its Speed control is inert because the index-scaling branch never installs a curve. The UI has one mouse card, so it reports "Blended acceleration 50 %" and a Speed value for both devices.
- **Impact:** with a Magic Mouse (Apple mice can expose `HIDAccelCurves` — `Decelerate/Core/AccelerationController.swift:856`: "Parametric curves exist on Apple trackpads (and some Apple mice)") plus any third-party mouse attached, the Magic Mouse loses its blended curve, silently gets a different acceleration model, and its Speed slider does nothing — inconsistent feel between two devices with no way to tell from the UI. The app reports success.
- **Proposed fix:** decide per service. On the curve path, install curves for services with `hasNativeCurves`; when the class is mixed, apply index scaling only if *every* service is table-only, and otherwise install curves on the curve devices and report the table devices as unsupported (or shape them with a constant user curve at the requested speed). Never `clearOverrides` a service that is about to receive a curve.
- **Evidence:** code trace of `route` → `performApply` `.indexScaling` branch (`:740-761`); `Notes` §6, and the comment at `Decelerate/Core/AccelerationController.swift:19-21` ("Devices that only have a classic acceleration table (most third-party mice)…"), which establishes that both representations occur in the mouse class. No mixed hardware was attached, so this is code-inspection only.

### DC-08 — the "no curves and no table means a real table device" shortcut bypasses the retry window for the mouse class

- **Severity:** Medium
- **Confidence:** Medium
- **Class:** correctness
- **Location:** `Decelerate/Core/AccelerationController.swift:681-690`
- **Code:**
```swift
            let classHasCurves = classServices.contains { $0.hasNativeCurves }
            let classHasTable = classServices.contains { $0.hasAccelerationTable }
            let treatAsTable = pointerClass == .mouse && !classHasCurves
                && (isFinalRetryAttempt || !classHasTable)
            if route == .unresolved {
                guard treatAsTable else {
                    needsRetry = true
                    continue
                }
```
- **Defect:** `.unresolved` is defined as "services exist but their acceleration representation cannot be read" and the retry series exists for it. But a service that is still being created, or a dead service returned by a stale client, reports **neither** `HIDAccelCurves` nor `HIDPointerAccelerationTable` — exactly the `!classHasTable` condition — so the mouse class takes the table shortcut on the *first* attempt (no retry at all): it index-scales the shared mouse parameters, clears any user curve, leaves `needsRetry` false, and records `appliedFingerprint`, which tells the watchdog the service set is shaped and suppresses healing. The trackpad class is protected from this by design; the mouse class is not. The comment justifies the shortcut with "verified on USB mice …", but the shortcut cannot distinguish that case from a transitional one.
- **Impact:** a curve-based mouse (Magic Mouse-class) that is being re-registered after wake, sleep, or a WindowServer restart can be index-scaled and have its user curve cleared, with the app reporting success and the watchdog refusing to repair it — the same silent-misshape class the 1.5.0 watchdog was added to prevent, surviving for the mouse class until relaunch.
- **Proposed fix:** drop the `|| !classHasTable` escape (accept the table interpretation only on `isFinalRetryAttempt`), or gate it on an independent, readable signal that the service is real and settled (product/transport/`HIDDeviceOpenedByEventSystem`), so "unreadable" is never mistaken for "table-only".
- **Evidence:** code trace plus `Notes` §5.1 (after sleep "an `IOHIDEventSystemClient` created before sleep keeps returning the dead service objects. Their `HIDAccelCurves` property is unreadable afterwards") and §5.2. Cannot be reproduced without a curve-capable mouse and a real sleep cycle.

### DC-09 — `install.sh` can report success while the old build is still running

- **Severity:** Medium
- **Confidence:** High
- **Class:** correctness
- **Location:** `Scripts/install.sh:20-35`
- **Code:**
```sh
osascript -e 'tell application "Decelerate" to quit' >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$DEST_DIR/Decelerate.app"
cp -R dist/Decelerate.app "$DEST_DIR/"
# (echo/mkdir lines elided)
for _ in 1 2 3 4 5; do
  pgrep -f "$DEST_DIR/Decelerate.app/Contents/MacOS/Decelerate" >/dev/null 2>&1 && break
  sleep 1
  open "$DEST_DIR/Decelerate.app" >/dev/null 2>&1 || true
done
if pgrep -f "$DEST_DIR/Decelerate.app/Contents/MacOS/Decelerate" >/dev/null 2>&1; then
```
- **Defect:** the quit is fire-and-forget with a fixed 0.5 s wait, and the `|| true` hides a real failure (e.g. no Automation permission for `osascript`, or the app is busy in its restore path). `rm -rf` then deletes the bundle while the old process may still be running. `open` on an app whose old instance is alive returns 0 and simply activates that instance (LaunchServices keys on the bundle identifier), and the readiness check uses `pgrep -f <path>`, which matches the **old** process because a process's argv does not change when its bundle is replaced. So the final message "Installed. Decelerate is running in the menu bar" is printed for the old binary, and the loop's `open` never gets a chance to launch the new one.
- **Impact:** the user believes an upgrade installed but is running the previous build from a deleted bundle (missing resources after `rm -rf`, no code changes visible, confusing behaviour when reporting bugs); the old instance's restore-on-quit writes HID state after its files are gone, and the next login then runs the new build on top of that state.
- **Proposed fix:** quit by bundle identifier, then **wait** for the PID to disappear (`for i in {1..25}; do pgrep -x Decelerate >/dev/null || break; sleep 0.2; done`, and fail loudly if it is still there), capture the old PIDs before quitting and verify after `open` that a *new* PID exists whose executable resolves under the new bundle (`lsof -p <pid> | grep Decelerate.app`), and do not swallow the `osascript` error.
- **Evidence:** code trace only; running it would replace the installed app, which is out of scope for a read-only audit.

### DC-10 — QA-only launch flags ship in the release build and rewrite persisted settings

- **Severity:** Low
- **Confidence:** High
- **Class:** security
- **Location:** `Decelerate/App/DecelerateApp.swift:96-101`, `:128-130`, `:145-160`
- **Code:**
```swift
        if arguments.contains("--restore-defaults") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                DebugLog.write("restore-defaults: invoking AppState.restoreSystemDefaults")
                AppState.shared.restoreSystemDefaults()
            }
        }
```
- **Defect:** `--restore-defaults` calls `AppState.restoreSystemDefaults()`, which clears the HID snapshot and rewrites both classes' persisted preferences to 100 %/1×/native scroll; `--test-login-item` calls `SMAppService.mainApp.register()` and then `unregister()`, removing the user's login item. Both are compiled into the shipping target with no `#if DEBUG` and no environment gate, alongside `--quit-after` and `--simulate-wake`.
- **Impact:** a user (or a support script) launching the installed app with those documented "development only" flags permanently loses their tuned settings or their login item, with the only signal being a debug line on stderr. The flags are discoverable in the README under `## Development`.
- **Proposed fix:** wrap `handleDebugArguments` in `#if DEBUG`, or gate on `ProcessInfo.processInfo.environment["DECELERATE_DEBUG"] == "1"`. Keep `--preview-*` behind the same gate (they are only needed for screenshots) and drop `--restore-defaults`/`--test-login-item` from Release.
- **Evidence:** code read; README `## Development` lists the flags as development-only, and both call sites are unconditional.

### DC-11 — `tapmeasure listen` never handles a disabled tap, so a dead tap still yields "results"

- **Severity:** Low
- **Confidence:** High
- **Class:** correctness
- **Location:** `Tools/Probe/tapmeasure.swift:47-58`, `:70-76`
- **Code:**
```swift
    let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let box = Unmanaged<AnyObject>.fromOpaque(refcon).takeUnretainedValue()
        if let acc = box as? SampleAccumulator {
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)
            acc.samples.append(Sample(t: CFAbsoluteTimeGetCurrent(), dx: dx, dy: dy, kind: "\(type.rawValue)"))
        }
        return Unmanaged.passUnretained(event)
    }
```
- **Defect:** the callback ignores `type`, so `kCGEventTapDisabledByTimeout` / `kCGEventTapDisabledByUserInput` are recorded as if they were samples, and `CGEvent.tapEnable(tap:enable:)` is never called again; the listen loop keeps spinning to its deadline and then prints event counts, percentiles and a CSV for whatever arrived before the tap died, with no warning. The run-loop source is also never removed before `CFMachPortInvalidate` (`:70`, `:76`).
- **Impact:** the delta rig can silently measure only part of the requested window — exactly under the fast-flick load it exists to measure — and the resulting CSV/gain table is then used as evidence for curve work (`Notes` §8 and `Tools/Probe/README.md` both point here). A truncated sample set looks like a real result.
- **Proposed fix:** in the callback, handle the pseudo-types first: `if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { CGEvent.tapEnable(tap: tap, enable: true); disabledCount += 1; return nil }`; print `disabledCount` with the summary and fail if it is non-zero. Remove the source from the run loop (`CFRunLoopRemoveSource`) before invalidating the port.
- **Evidence:** code read; no measurement run (needs physical input and Accessibility/Input Monitoring).

### DC-12 — a wrong-typed field discards the whole preference blob, resetting both classes to defaults

- **Severity:** Low
- **Confidence:** High
- **Class:** correctness
- **Location:** `Decelerate/Core/PointerSettings.swift:137`, `:142`, `:148`; `Decelerate/Core/PreferencesStore.swift:126-128`
- **Code:**
```swift
        if let amount = try container.decodeIfPresent(Double.self, forKey: .accelerationAmount) {
            // Values written by a future/buggy build must never reach the HID
            // path or the sliders out of range; the Speed decoder already
            // clamps for the same reason.
            accelerationAmount = min(max(amount, 0), 1)
        } else if let removed = try container.decodeIfPresent(Bool.self, forKey: .removeAcceleration) {
```
```swift
    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
```
- **Defect:** `decodeIfPresent` only returns nil when the key is absent or null; a key with the wrong type throws. `try?` turns that into nil, `load()` substitutes `CategoryPreferences()` for that class, and `start()` applies 50 %/1.5× immediately. The decode is all-or-nothing, so one bad field also discards the other, perfectly readable fields, and the numeric form of the v1 key (`"removeAcceleration": 1`, e.g. from a JSON conversion of a plist) does not migrate.
- **Impact:** a partially corrupted or hand-edited `pointer.trackpad`/`pointer.mouse` blob silently replaces the user's tuned values with defaults and applies them to the HID system; nothing in the UI says settings were reset.
- **Proposed fix:** decode each field independently (`(try? container.decodeIfPresent(Double.self, forKey: .accelerationAmount)) ?? nil`) with the existing clamps as the fallback, and accept `removeAcceleration` as `Bool` or `NSNumber` (`(try? container.decodeIfPresent(Bool.self, …)) ?? ((try? container.decodeIfPresent(Int.self, …)).map { $0 != 0 })`).
- **Evidence:** `/tmp/code-audit/probes/decodeprobe/` (output in `decodeprobe.out`): valid blob OK (`0.347 / 1.85`); `{"accelerationAmount":"0.347","speedMultiplier":1.85}` **throws** → defaults; `{"removeAcceleration":1}` **throws** → defaults; `{"removeAcceleration":true}` migrates to amount 0; out-of-range values clamp to 1.0 / 2.0.

### DC-13 — Launch-at-login can show ON while macOS still requires approval

- **Severity:** Low
- **Confidence:** Low
- **Class:** correctness
- **Location:** `Decelerate/App/AppState.swift:329-335`, `:296-311`
- **Code:**
```swift
        if store.launchAtLogin, Self.isInstalledLocation {
            do {
                try SMAppService.mainApp.register()
                launchAtLogin = true
                store.launchAtLogin = true
                DebugLog.write("launch-at-login: re-registered after the bundle moved")
                return
```
- **Defect:** `SMAppService.register()` succeeds when the item becomes registered but still needs user approval (status `.requiresApproval`); only `.enabled` means it will actually run. Both the explicit toggle path (`updateLaunchAtLogin`, `:298-304`) and this re-registration path set `launchAtLogin = true` and persist it purely on "register() did not throw"; `.enabled` is the only status the code treats as authoritative, and the re-registration path above bypasses even that check. The toggle therefore claims the app starts at login while System Settings shows it as pending approval (and it will not start).
- **Impact:** the app silently fails to start at login after an install/move, which is exactly the "deceleration stopped working with no app around" symptom the surrounding comment is trying to prevent; the user has no indication that an approval step is pending.
- **Proposed fix:** after `register()`, re-read `SMAppService.mainApp.status` and only report enabled for `.enabled`; surface `.requiresApproval` as its own state with copy pointing at System Settings → General → Login Items (and keep the stored intent only as intent).
- **Evidence:** code read; `SMAppService` status transitions would need a runtime check on a fresh install.

## Checked and clean

- **Apply/restore write order** — all three shaping paths write HID parameters before installing curves (`performApply` 0 % branch `:703-712`, `.curves` `:724-728`, `applyScroll` `:1005-1010`), which is the documented invariant ("a parameter write that follows the curve install silently hands the pointer back to macOS"). The curve is always the last write.
- **Snapshot integrity** — `write()` records the *live* value on a rejected write (`:1181-1193`), `isPlausibleOriginal` fences 8192…196608, `com.apple.*.scaling` is treated as ground truth, and `captureOriginalsIfNeeded` refuses to adopt a value equal to `lastWritten`. The round-2 N1 logic is intact. Scaled writes are fenced off from the snapshot (`writeScaled`, `:1200-1210`).
- **Snapshot retention on failed restore** — `restoreSystemState` clears per-service curves regardless of the parameter connection (`:807-820`), treats a missing event system as failure (`:812`, `:828-830`), and returns without clearing `originals`/`lastWritten` when anything was rejected (`:832-841`). Prior findings 1 and 2 are genuinely fixed, not papered over.
- **Termination path** — `applicationWillTerminate` → `AppState.prepareForTermination` → `controller.prepareForTermination` sets `isTerminating` first, then stops monitoring and restores. `attemptApply`, `reapply`, `systemParameterChanged` and the deferred-change work item all check `isTerminating`, so no apply can run after the restore.
- **Concurrency / actor contract** — `AppState` and `AccelerationController` are `@MainActor`; every C callback (HID property change, `IOHIDManager` match/removal, `Timer`) either dispatches to the main queue or goes through the private `OnMain` helper before touching state; `HIDPointerControl` and `HIDServiceBridge` are only reached from main-actor code. No background queues, no locks, no `Task.detached` in the app. The `Task { @MainActor … }` in `systemParameterChanged` is bounded and guarded by `attemptApply`'s `isTerminating` check.
- **Observer and timer lifecycle** — both notification arrays are removed in `stopMonitoring`, each from the correct center (`NSWorkspace.shared.notificationCenter` for wake/screens-wake, `NotificationCenter.default` for activation, `:405-419`); the watchdog `Timer` is invalidated and the deferred work item cancelled (`:519-525`); `HIDDeviceScanner.stopMonitoring` unschedules from the main run loop, closes the manager and nils both callbacks. No timer/observer leak found.
- **Retain cycles** — every stored closure is `[weak self]`; the C callback contexts pass unretained references to singletons that outlive them (`HIDDeviceScanner` is owned by `AccelerationController.shared`; `HIDPointerControl` likewise). `previewWindows` only grows in dev preview mode.
- **Service-ref lifetime** — `HIDPointerService.ref` is an unretained `IOHIDServiceClient`, but every use is inside the lifetime of the owning `HIDServiceBridge.client` (no `refresh()` between obtaining services and writing to them). A probe confirmed a service ref still answers `CopyProperty` after the `CopyServices` array is released while the client is alive; the array is not the sole owner.
- **No HID handle leak** — 300 `IOHIDEventSystemClientCreate` + `CopyServices` + destroy cycles left the process fd count unchanged (4 → 4). The 2 s churn is a latency problem (DC-02), not a descriptor/memory leak.
- **No event tap, no TCC, no entitlements in the app** — there is no `CGEventTap`, no root prompt, no TCC API and no `.entitlements` file anywhere under `Decelerate/`; the permission stubs (`needsPermission`, `refreshPermissionStatus`, `requestPermissionIfNeeded`) are inert by design and no UI depends on them. The only tap in the tree is `Tools/Probe/tapmeasure.swift` (DC-11), which is research-only and not built into the app.
- **Scroll/pointer class isolation** — scroll services are routed by `HIDScrollAccelerationType`, only the class's own type-specific key is written, the machine-wide `HIDScrollAcceleration` is never a shaping target, and a key another attached class resolves to is skipped (`scrollKeysResolvedByOtherClasses`). The generic key is snapshotted/restored only.
- **No zoom/magnify or horizontal-scroll handling** — nothing in the app intercepts or special-cases magnify/zoom or horizontal scroll; the scroll curvature is applied by the HID filter to all scroll axes, and there is no sign handling outside `negated()` (DC-01). No per-axis code exists to be wrong.
- **Curve math for non-inverted curves** — factor clamped to 0…1 and speed to 0.1…8 at `AccelerationCurveBuilder.curves` (`AccelerationCurveBuilder.swift:44-45`), so no NaN/overflow can reach `fixed()`; `cbrt`/`quarticRoot` guard non-positive inputs; the `s, √s, ∛s, ⁴√s` scaling is algebraically correct for `gain'(v) = s·gain(v)`; `tailScale` matches the §5 lookup points; blend is monotone in `f` and `v` for `f > 0`; 100 %/1× clears the override and hands control back.
- **Settings migration** — pre-1.5 installs decode scroll fields as native (scroll untouched), v1 `removeAcceleration` booleans migrate (true → 0 %, false → 100 %), speed and amounts clamp on decode and in every setter (probe: 2.0 → 1.0, 9 → 2.0). Only the all-or-nothing failure mode (DC-12) is wrong.
- **Scripts (other than `install.sh`)** — `build.sh` uses `set -euo pipefail`, quotes every path, and its only destructive command is `rm -rf dist` inside the repo; `windowshot.swift` shells out to a fixed `/usr/sbin/screencapture` path with an argument array (no shell interpolation); `check-state.py`/`verify-applied.py`/`filterlog.sh` are read-only (`defaults read`, `ioreg`, `log show`, `hidprobe pointers`) and use argument arrays, never `shell=True`; `tcc-test.sh` writes only under `/tmp`.
- **No unsafe unwraps in the app** — no `as!`, `try!`, `fatalError`, or force-unwrapped optionals in `Decelerate/`; all CoreFoundation values are cast with `as?` and optional-bound, and `CFArrayGetValueAtIndex` results are checked for nil (`Decelerate/Core/HIDServiceBridge.swift:160-161`, `:204-205`).
- **Project/security posture** — matches the documented requirement: not sandboxed, hardened runtime off, ad-hoc signed, `LSUIElement`, deployment target 14.0, no entitlement file, private symbols resolved with `dlsym` on `RTLD_DEFAULT`. Builds clean in Debug and Release with no `*.swift` warnings.

## Prior-audit disposition

- **2026-11-12 #1** (restore returned early / dropped the snapshot) — **FIXED.** `restoreSystemState` now clears per-service curves independent of the parameter connection (`:807-820`), marks unavailable as failure (`:812`, `:828-830`), and keeps `originals`/`lastWritten` on any rejection (`:832-841`).
- **#2** (`clearOverrides` gated on an in-memory set) — **FIXED.** `clearOverrides` is unconditional (`:919-926`) and is called from every hand-back path, including `.absent` and `.indexScaling`.
- **#3** (silent retry exhaustion / unchecked `bridge.isAvailable`) — **FIXED.** `bridge.isAvailable` is checked and reported (`:621-627`), `lastError` is set when the retry window closes (`:471-482`), and `changeHandler?()` refreshes the observable status after a successful retry series and after exhaustion (`:463-469`).
- **#4** (Restore System Defaults left Speed untouched) — **FIXED.** `AppState.restoreSystemDefaults` resets amount, speed, scroll amount, scroll speed and invert before re-applying (`:271-289`).
- **#5** (decoded amount not range-checked) — **FIXED** at `PointerSettings.swift:137-141`; out-of-range values clamp (probe). Residual note: the clamp cannot reject NaN, but no reachable path delivers NaN (JSON cannot carry it, and all UI setters clamp), so this is not counted as a finding.
- **#6** (docs described the retired negative-sentinel mechanism) — **FIXED** for the pointer mechanism (`README.md:25-50`, `Notes` §13, `HIDPointerControl` doc comment). **New drift** arrived with the 1.5.0 scroll feature: `README.md:71` still says scroll is untouched (DC-05), and `Notes` §11 still cites the retracted 1/kCursorScale formula (DC-04).
- **#7** (deprecated activation APIs) — **FIXED.** No `NSApp.activate(ignoringOtherApps:)` or `.activateIgnoringOtherApps` remains; `SettingsPresenter.activateNow()` uses `NSRunningApplication.current.activate(options: [.activateAllWindows])` plus `NSApp.activate()` (`Decelerate/App/DecelerateApp.swift:53-64`).
- **#8 / N3** (status model ignored a speed-only override) — **FIXED** for pointer and speed: `AppState.isEnabled` counts a non-1× speed (`:108-114`), `activeSummary` and the card captions distinguish "macOS curve at N× speed" from "macOS default acceleration", and the pill says "Custom" (`Decelerate/UI/Components/StatusBadge.swift:64-71`). Residual, not counted: the pill's `isIdentity` ignores scroll, so a 0 %/1× pointer with inverted scroll still reads "1:1 Pointer" — the label is about the pointer and the card directly below shows the scroll caption.
- **Deferred D1** (restore enumerates services once) — **N/A**, still one pass (`:816`); no change, no regression.
- **Deferred D4** (`HIDPointerControl` never unregisters property callbacks) — **STILL PRESENT**, still harmless: the object is owned by the `AccelerationController` singleton, `stopMonitoring` leaves the callbacks registered, and `isTerminating` gates the handler so no work runs post-restore. Not promoted to a finding.
- **Deferred D5** (historical `PointerAccelerationController.swift`) — **N/A**, still annotated as historical in `Tools/Probe/README.md:24-29`.
- **Deferred D6** (historical `Notes` sentinel sections) — **STILL PRESENT** for §7/§11 (DC-04), which is no longer purely historical: §11 asserts the current coefficients match the retracted formula.

## Test-coverage gaps

There is no test target; this is the order I would build one in, highest value first.

1. **`AccelerationCurveBuilder`** (pure, no IOKit): identity at f = 0 produces the documented 1:1 coefficient set; monotonicity of gain in v and of the blend in f; speed scaling `s, √s, ∛s, ⁴√s` reproduces `s·gain(v)`; `tailScale` matches the §5 table; `fixed()` never traps for clamped inputs; and a property test that **any curve with `invert` stays negative over v ∈ [0, 200]** (catches DC-01 and any regression of the identity constant, DC-04).
2. **`CategoryPreferences` decode matrix**: v1 boolean, absent fields, wrong types, numeric legacy key, out-of-range, NaN/inf strings (catches DC-12).
3. **`macOSSettingRaw` with an injected `UserDefaults`**: 0.6875, 2.5, 31999, 32768, 1e300, NaN, a string, a boolean — asserting no trap (catches DC-03). Requires making `UserDefaults` injectable instead of `.standard`.
4. **Route selection and `treatAsTable`** over fabricated `HIDPointerService` values: absent, all-curves, all-table, mixed-representation, unreadable-on-attempt-0, unreadable-on-final-attempt (catches DC-07, DC-08).
5. **`write` / `writeScaled` / `writeScrollScaled` against a fake parameter store**: skip-when-equal, `lastWritten` = live on rejection, `min(scaled, base)`, floor of 1, and that a rejected write never lets a later capture adopt the scaled value (protects the round-2 N1 fix).
6. **Restore state machine with a fake bridge**: failure keeps the snapshot, success clears pointer and scroll snapshots, a nil event-system client counts as failure, and curves are cleared even when the parameter connection is unavailable (protects prior findings 1/2).
7. **Apply coalescing** once DC-06 is fixed: assert one apply per drag instead of one per slider tick.
8. **Launch-at-login state mapping** with a fake `SMAppService` wrapper (`.enabled`, `.requiresApproval`, `.notRegistered`) (catches DC-13).

Not unit-testable (keep on the probe path): real curve installation (`UserPointerAccelCurvesKey` is write-only), service replacement across sleep/wake, TCC state, and delivered gain (needs physical input).

## Needs runtime verification

- **DC-01 (invert):** on a mouse whose service exposes `HIDScrollAccelCurves` (`bin/hidprobe dump --pointer-only` shows the property), turn `Invert scroll direction` on with Scroll at 100 %, then scroll slowly and fast. Expect the direction to be wrong only at very low speed (and never above ~0.7 in/s). On a table-only mouse, set Scroll to 50 % with invert on and confirm the amount slider has no effect. `filterlog.sh` should show the `UserScrollAccelCurvesKey` array with negative gains.
- **DC-02 (watchdog):** with the app at the default 50 %/1.5×, run `sample Decelerate 10` and look for `IOHIDEventSystemClientCreate` ≈100 ms on the main thread every 2 s; open the panel and Settings and watch for hitching. Also confirm the app is quiet (no tick) when every class is native at 1×.
- **DC-03 (trap):** on a throwaway account or VM, `defaults write -g com.apple.trackpad.scaling 40000`, launch `dist/Decelerate.app`, expect a crash before any window; then `defaults delete -g com.apple.trackpad.scaling` and relaunch. (Do not do this on the primary account without noting the previous value.)
- **DC-06 (write cost):** with a table-only mouse attached, drag the Acceleration slider while running `sample Decelerate 5`; check that each tick shows two `IOHIDSetCFTypeParameter` calls (~20–40 ms) and six `UserDefaults` writes. Also time Quit.
- **DC-07 (mixed mice):** attach a Magic Mouse and a third-party mouse together, set the mouse class to 50 %/1.5×, then compare `hidprobe pointers` + `filterlog.sh`: the Magic Mouse should receive `UserPointerAccelCurvesKey`, and with the current code it will not. Feel both devices and the Magic Mouse's Speed slider.
- **DC-08 (post-wake mouse):** with a curve-based mouse, sleep/wake for real (`--simulate-wake` does not recreate HID services), then check `filterlog.sh` for `HIDMouseAcceleration` index writes from the first apply instead of a curve install, and whether the mouse keeps its blend.
- **DC-09 (install):** run `./Scripts/install.sh` while the app is running; before trusting the message, compare the PID's start time and `lsof -p <pid> | grep Decelerate.app` to see which build is actually running.
- **DC-13 (login item):** fresh install, toggle Launch at login, decline the approval prompt, relaunch, and compare the toggle with System Settings → General → Login Items.
- **Manual feel (the contract itself):** the shipped claim that 0 % at Speed 1× is "geometry-true 1:1" (`Decelerate/Core/PointerSettings.swift:77-82`, `README.md:118`) and that 100 %/1× hands control back to macOS. Measure with `tapmeasure listen 20 --csv …` while moving the pointer at known speeds, once at 0 %/1× and once at 100 %/1×, and compare against `Notes` §12's 0.24 points/count model. This is the only way to confirm the gain model that DC-04's tooling disagrees with; it needs a trackpad and a human.
- **Quit/restore on real hardware:** `DECELERATE_DEBUG=1 dist/Decelerate.app/Contents/MacOS/Decelerate --quit-after 6`, then `python3 Tools/Probe/check-state.py` before/after and `python3 Tools/Probe/verify-applied.py` (expect exit 0 with a fresh log window). Not run by this audit because the app was already running and the audit was read-only.
