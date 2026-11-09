# Continuous acceleration amount (task-3): source-derived math + verified plumbing

Machine: macOS 26.0.1 (25A362), Apple M-series. All experiments run live on 2026-11-08/09
by `hid-researcher`; every write was restored; final state is the original one (§10).
Read with `Notes/acceleration-research.md` (the binary 1:1/disabled mechanism).

---

## 1. TL;DR — what to ship

A 0–100 % "Acceleration amount" slider is possible **without any event tap**, using the
filter's user-curve property (verified route) plus a source-derived blend formula.

| Slider | Trackpad (parametric native) | Mouse with `HIDAccelCurves` (parametric) | Mouse table-only |
|---|---|---|---|
| **0 %** | disable acceleration: write **negative** `HIDTrackpadAcceleration` (raw −65536) as today | negative `HIDMouseAcceleration` | same |
| **1–99 %** | install one blended curve via per-service `UserPointerAccelCurvesKey` (formula §4) | same, using the mouse's native curve | **do not ship intermediates** — keep 0 % / 100 % only (see §6); table baseline cannot be reproduced safely |
| **100 %** | clear curves (`UserPointerAccelCurvesKey` = empty array) → filter falls back to native `HIDAccelCurves` | clear curves → native | clear curves → native table |

**Critical correction to the earlier coefficient formula:** the identity term must be
scaled by `1/kCursorScale = 67/96`, not 1. The filter multiplies every algorithmic
output by `kCursorScale = 96/67` (`IOHIDAccelerationAlgorithm.hpp: kCursorScale`;
`multiplier()` returns `... * kCursorScale`). Therefore a 1:1 parametric curve needs
`GainLinear = 67/96`, and the blend is

```
GL' = (1-f)/KC + f*GL_n
GP' = sqrt(f)  * GP_n
GC' = f^(1/3)  * GC_n
GQ' = f^(1/4)  * GQ_n
TSL' = TSL_n, TSPR' = TSPR_n   (see §5 for f<0.25 tail handling)
```

where `KC = 96/67`. If you use `GL' = 1 + f*(GL−1)` the slider jumps from true 1:1
(gain 1.0 at f=0, the disabled mechanism) to gain ≈ `KC` = 1.43 at f→0+. Evidence for
the 1/`KC` identity factor: `IOHIDSimpleAccelerator(value)` multiplies deltas by
value directly, and the linear-scaling path is documented/implemented as
`delta_out = delta_in * HIDMouseAcceleration` — so value 1.0 is raw passthrough
(gain 1.0). The parametric algorithm's `multiplier()` adds `kCursorScale`, so its
coefficients live in different units.

---

## 2. Verified plumbing (all live, WindowServer debug log as ground truth)

Debug log command used for verification (read-only, no root):

```bash
log stream --debug --style compact \
  --predicate 'process == "WindowServer" AND subsystem == "com.apple.iohid"'
```

It prints, at debug level, Apple's internal `HIDLogDebug` lines from
`IOHIDPointerScrollFilter` / `IOHIDAccelerationAlgorithm`: property events,
`Pointer acceleration value`, `acceleration <a> resolution <r> rate 67`,
`table index <n>` (parametric curve selection) and `Acceleration table ...`
(full parsed table). This is the best development oracle; the shipping app must not
depend on it.

### 2.1 Working route for user curves

```
service = pointer event service (trackpad: registry 0x1000bf484 / AppleMultitouchDevice)
IOHIDServiceClientSetProperty(service, "UserPointerAccelCurvesKey", CFArray of curve dicts)
```

- The key string is literally **"UserPointerAccelCurvesKey"** (Lead verified from the
  filter's own debug output; independently reproduced here). It corresponds to
  `kIOHIDUserPointerAccelCurvesKey` in Apple's source and is in the filter's
  `_cachedPropertyList`, so it is one of the few keys whose per-service write both
  reaches the filter and triggers `setupAcceleration()`.
- On write the debug log shows:
  `Acceleration key:UserPointerAccelCurvesKey value:( ...` then
  `acceleration 2.000000 resolution 400.000000 rate 67.000000` then `table index 0`
  (0 = index of our single curve in the supplied array; baseline without user curves
  shows `table index 7`, the native 10-curve selection for HIDTrackpadAcceleration=2.0).
- **Persistence:** the value is cached in the filter's `_property` dict and survives
  later rebuilds in the same filter instance. Verified across three different rebuild
  triggers: (a) another cached key write (`HIDScrollAcceleration`), (b) a kernel-param
  write (`IOHIDSetCFTypeParameter`, which arrives via `IOHIDSetHIDParameterToEventSystem`),
  (c) rewriting `HIDTrackpadAcceleration` — all three re-ran setup and still logged
  `table index 0`.
- **Clearing (f = 100 %):** writing an **empty CFArray** to `UserPointerAccelCurvesKey`
  and triggering a rebuild makes the log return to `table index 7` (native fallback:
  `createPointerParametricAlgorithm` requires `userCurves.Count() > 0`; otherwise it
  reads service `HIDAccelCurves`). This is the clean f=1 "no intervention" state; it
  also overwrites the cached `_property` value, so no stale curves remain. Verified.
- Writes must go through the **full** `IOHIDEventSystemClient` (dlsym
  `IOHIDEventSystemClientCreate`); `IOHIDEventSystemClientCreateSimpleClient` returns
  `false` for these SetProperty calls (see previous notes).
- Kernel-param writes (`IOHIDSetCFTypeParameter(handle, "HIDUserPointerAccelCurves"...)`)
  do **not** reach the filter (Lead verified; reproduced the same conclusion from the
  cache/read paths). Event-system-client-level SetProperty also does not reach it.
  Per-service SetProperty is the only working route.

### 2.2 TABLE route — tested end-to-end, does NOT work (do not use)

The filter can also be rebuilt from `HIDPointerAccelerationTable` (CFData) when
`HIDPointerAccelerationAlgorithm` is forced to Table (0). Test on the trackpad:

1. Read the table: `IOHIDServiceClientCopyProperty(trackpadSvc, "HIDPointerAccelerationTable")`
   = CFData, 771 bytes, MT signature, 7 entries, scale 0.5, big-endian IOFixed x/y
   points. (It is 1 byte short of the format's expectation: 7 entries with the last
   count=15 should total 772 bytes = 10 + 7*6 + 8*90. The last point's low byte is
   missing in the live property.)
2. Wrote a modified table via `IOHIDServiceClientSetProperty`: entry0 point1 y changed
   16.0 → 9.0 (raw `0x00100000` → `0x00090000`), then forced
   `HIDPointerAccelerationAlgorithm = 0`. The write was accepted (`true`), the filter
   did rebuild from a table (debug: `Acceleration table  Table: ...`,
   `table index 1`), **but its parsed dump printed `y: 16(100000)` — the original
   value, not 9.0.**
3. Conclusion: `HIDPointerAccelerationTable` is not in `_cachedPropertyList`, so no
   property event is delivered; and the transient per-service property is not visible
   to `IOHIDServiceCopyProperty(_service, kIOHIDPointerAccelerationTableKey)` used by
   `createPointerTableAlgorithm`. The table the filter uses is always the
   kernel/driver one. `HIDPointerAccelerationAlgorithm` (which *is* cached) is delivered
   and does switch the algorithm — that part works.
4. Additional reason to avoid it: the live blob is truncated by one byte for the MT
   table (above), i.e. even the built-in data doesn't follow a clean byte count.

So: **no user-space table installation on macOS 26.** The parametric user-curve route
is the only way to change the acceleration curve.

### 2.3 What the filter reads (source, IOHIDFamily main)

`IOHIDPointerScrollFilter::createPointerAlgorithm`:

1. If `HIDPointerAccelerationAlgorithm` override is present: 0=Table, 1=Parametric,
   2=Default (fall through to normal selection). (Confirmed by behaviour: 0 switched to
   the table path; 2 restored the parametric path. Enum order matches the source switch.)
2. Otherwise `createPointerParametricAlgorithm`: read
   `kIOHIDUserPointerAccelCurvesKey`; `Count() > 0` → use those curves; else read service
   `HIDAccelCurves` ("HIDAccelCurves"); else `createPointerTableAlgorithm`: service
   `HIDPointerAccelerationTable`, else the compiled-in `defaultAccelTable`.
3. `_pointerAcceleration` comes from the type key (`HIDTrackpadAcceleration` /
   `HIDMouseAcceleration` / `HIDPointerAcceleration`); negative ⇒ no accelerator at all
   (the 1:1 disabled mechanism).
4. Curves are selected/interpolated by `HIDAccelIndex` against `_pointerAcceleration`:
   if the acceleration value falls between two curve entries, coefficients and tangent
   speeds are linearly interpolated by index ratio; if the value is above all entries,
   the highest curve is used; if our array has a single entry with Index 0, it is used
   verbatim for any non-negative acceleration value.
5. Freeze/rebuild: the plugin reads curve/table properties when it (re)builds the
   accelerator, on property events for cached keys and at open/setup.

---

## 3. Source facts used (exact paths/lines, apple-oss-distributions/IOHIDFamily @ main)

- `IOHIDEventSystemPlugIns/IOHIDPointerScrollFilter.cpp`
  - `_cachedPropertyList` (≈356–378): includes `HIDUserPointerAccelCurves` (as
    `kIOHIDUserPointerAccelCurvesKey`), `HIDPointerAccelerationMultiplier`,
    `HIDPointerAccelerationAlgorithm`, `HIDPointerAccelerationMinimum`, the
    acceleration type/value keys. (Table key absent — hence §2.2.)
  - `createPointerParametricAlgorithm` (≈646–660): userCurves `Count()>0` gate; then
    service `HIDAccelCurves`.
  - `createPointerAlgorithm` (≈666–688): algorithm override switch; parametric tried
    first, table fallback.
  - `setupPointerAcceleration` (≈781–894): resolution from service
    `HIDPointerResolution`; type-key lookup; `_pointerAcceleration < 0` ⇒ return (no
    accelerator); linear-scaling branch for `isMouseAcceleration` only.
- `IOHIDEventSystemPlugIns/IOHIDAccelerationAlgorithm.cpp` /
  `.hpp` — `IOHIDParametricAcceleration`:
  - curves are CFArray of CFDictionary with IOFixed keys `HIDAccelIndex`,
    `HIDAccelGainLinear`, `HIDAccelGainParabolic`, `HIDAccelGainCubic`,
    `HIDAccelGainQuartic`, `HIDAccelTangentSpeedLinear`,
    `HIDAccelTangentSpeedParabolicRoot`;
  - segments: f1 = GL·v + (GP·v)² + (GC·v)³ + (GQ·v)⁴ for v ≤ TSL;
    f2 = m0·v + b0 (tangent of f1 at TSL) for TSL < v ≤ TSPR;
    f3 = sqrt(m1·v + b1) (tangent of f2 at TSPR) above; special cases for TSL==0 /
    TSPR==0; `multiplier()` standardises v by resolution/rate and returns the result
    × `kCursorScale` (96/67);
  - `serialize()` output (also used by `ServiceFilterDebug`): Class
    `IOHIDParametricAcceleration`, `AccelIndex`, `GainLinear`, `GainCubic`,
    `GainParabolic`, `TangentSpeedLinear`, `TangentSpeedParabolicRoot`
    (note: `GainQuartic` is NOT serialized).
- `IOHIDEventSystemPlugIns/IOHIDAccelerationTable.cpp` / `.hpp`,
  `IOHIDPointerScrollFilter.cpp` `defaultAccelTable` — table format
  (`ACCEL_TABLE`= scale u32, signature u32, count u16; entries = acceleration u32 BE,
  count u16 BE, points (x,y) s32 BE; `multiplier()` piecewise linear in
  resolution/rate-scaled x with y × `kCursorScale`).
- `IOHIDEventSystemPlugIns/IOHIDPointerScrollFilter.h` — `kDefaultPointerResolutionFixed
  = 400<<16`, `kIOHIDDefaultReportRate = 60.0`, FRAME_RATE = 67.0 used as the rate in
  the algorithm constructors.
- `IOHIDEventSystemPlugIns/IOHIDAcceleration.cpp` — `IOHIDPointerAccelerator::accelerate`:
  velocity = floor(sqrt(dx²+dy²)) × rate/fixed multiplier; gain = multiplier/v;
  `IOHIDSimpleAccelerator::accelerate` = multiply by value (linear-scaling path).

The compiled-in mouse table (`defaultAccelTable` in the filter source, 102 bytes,
signature 0x30303240, 2 entries: accel 0 with a single (1,1) point, accel 1.0 with 9
points) parses exactly with the same format; see §6 for why it is not usable for
intermediate blends.

---

## 4. Blend formula (trackpad baseline, exact derivation)

Definitions (per source):

```
KC      = kCursorScale = 96/67
v       = released velocity in counts/event (after the accelerator's rate multiplier)
v_std   = v / (resolution/rate),  resolution = 400 for the built-in trackpad,
          rate = FRAME_RATE = 67  →  resolution/rate = 400/67
S(v)    = algorithmic "accelerated speed" (standardized units)
gain(v) = KC * S(v) / v          # applied delta multiplier
```

Native macOS curve (f = 1) for the current setting `HIDTrackpadAcceleration = 2.0` is
exactly curve entry #7 of the 10 `HIDAccelCurves` (Index 2.0):

```
GL = 56361/65536 = 0.86000061
GP = 95027/65536 = 1.44999695
GC = 15729/65536 = 0.24000549
GQ = 0
TSL = 458752/65536 = 7.0
TSPR = 917504/65536 = 14.0
```

For a general acceleration value, apply Apple's index interpolation first (linear by
Index ratio between adjacent entries) — the app should mirror `CreateWithParameters`
exactly so f=1 matches the live baseline.

We want

```
gain_f(v) = (1-f)*1 + f*gain_native(v)          (gain-domain linear blend)
⇔ S_f(v)  = (1-f)*(v/KC) + f*S_native(v)        (so f=0 is exact 1:1 passthrough)
```

This is representable exactly for segments 1 and 2 by scaling coefficients:

```
GL' = (1-f)/KC + f*GL_n
GP' = sqrt(f) * GP_n
GC' = f^(1/3) * GC_n
GQ' = f^(1/4) * GQ_n
TSL' = TSL_n, TSPR' = TSPR_n
```

Proof: segments 1–2 of the rebuilt parametric algorithm are polynomial/tangent line in
the coefficients, and both the polynomial and its tangent construction are linear in the
coefficients:
S_f(v) = (1-f)·(v/KC) + f·S_n(v), so f1_f = (1-f)v/KC + f1_n, m0_f = (1-f)/KC + f·m0_n,
b0_f = f·b0_n, y1_f = (1-f)·TSPR/KC + f·y1_n, m1_f = 2·y1_f·m0_f,
b1_f = y1_f² − m1_f·TSPR. Segment 3 is the only approximation: the algorithm only allows
a sqrt curve tangent-matched at TSPR; it matches value and slope at the breakpoint, and
its error is quantified in §5.

Property: gain_f(v) is pointwise linear/monotone in f from 1 (f=0) to gain_native(v)
(f=1). Output speed S_f is strictly increasing in v for every f∈[0,1] (derivative
(1-f)/KC + f·S_n'(v) > 0), so no reversed/jittery movement — checked numerically over
v∈[0,100] in `Tools/Probe/curve_math.py --analysis`.

Numeric check (trackpad baseline, `curve_math.py`): rebuilt-from-coefficients vs the
ideal blend has ZERO error for segments 1–2; measured max |gain error| over v∈[0,150]
for Scheme A (native TSPR):

| f | max err | at v | min gain in [0,150] |
|---|---|---|---|
| 0.01 | 0.571 | 150 | 0.587 ← sub-1 tail, avoid |
| 0.05 | 0.547 | 150 | 1.03 |
| 0.10 | 0.517 | 150 | 1.05 |
| 0.25 | 0.431 | 150 | 1.13 |
| 0.50 | 0.287 | 150 | 1.27 |
| 0.75 | 0.144 | 150 | 1.40 |
| 0.90 | 0.057 | 150 | 1.48 |

The whole residual is the sqrt-tail approximation at the extreme end of the velocity
range (v≈150 standardized ≈ an extremely fast flick); at normal speeds the curve is
exact by construction.

---

## 5. Tail handling (TSPR choice) — the only place the blend deviates

At small f the native sqrt tail shrinks and, if TSPR is left at the native 14, the
rebuilt sqrt segment can produce gain < 1 at high v (decelerating tail, table above:
f=0.01 min gain 0.587). Three options were evaluated numerically (v∈[0,150]; error =
max |gain_f − ideal|):

| strategy | f=0.05 | f=0.10 | f=0.25 | f=0.50 |
|---|---|---|---|---|
| A: TSPR = native | 0.547 @150, minG 1.03 | 0.517, minG 1.05 | 0.431, minG 1.13 | 0.287, minG 1.27 |
| B: per-f optimum TSPR (search) | 0.250 @29 | 0.272 @27 | 0.291 @150 | 0.287 @150 |
| C: TSPR × 1/f (suggested earlier) | 1.42 @150 | 2.83 | 4.88 | 5.29 |

**Recommendation: B, via a small lookup table**, because it removes the sub-1 tail while
keeping the error ≤ ~0.27 gain units in a normal speed range. For f ≥ 0.25 the native
TSPR is already optimal; below 0.25 scale TSPR up:

```
f <= 0.01  → TSPR_scale 3.15      f = 0.05 → 1.50
f = 0.02   → 2.20                 f = 0.10 → 1.25
f = 0.15   → 1.15                 f >= 0.25 → 1.00
```

(interpolate linearly in f; `TSPR_raw = round(917504 * scale)`). Alternatively, if you
prefer a formula, `TSPR_scale = 1 + 2.15 * max(0, 0.25 - f)` gets close to the optima
(0.01→1.52 vs 3.15 optimum → slightly larger error at tiny f but min gain stays ≥1 if
combined with the slider's f=0 disable path). Full generated lookup including raw
coefficients for f = 0.01 … 0.99 is in
`Tools/Probe/out/trackpad-accel-amount-table.json`.

`TSL` is always kept at the native value; changing it is unnecessary (segments 1–2 are
exact for any breakpoint because the tangent construction is linear in the coefficients).

Slider semantics: 0 % = the existing negative-value disable path (exact 1:1 raw
passthrough); 1–99 % = blended user curve; 100 % = clear the user curve (empty array) so
the filter uses the native macOS curves/table untouched. Continuity at 0 % holds because
the f→0+ curve tends to identity (error ≤ ~0.15 gain units at f=0.01 with strategy B).
Continuity at 100 % for trackpad/parametric-mouse is exact (the f=1 coefficient set is
identical to the native curve, and clearing the override is a no-op). For table-only
mice do not offer intermediates (§6).

---

## 6. Per-class plan

### Trackpad (and any device whose service exposes `HIDAccelCurves`)
1. Baseline: read `HIDAccelCurves` (full client
   `IOHIDServiceClientCopyProperty(svc, "HIDAccelCurves")`, CFArray of 10 dicts; also
   present in IORegistry, 400 dpi, rate 67) and the current
   `HIDTrackpadAcceleration`/`HIDMouseAcceleration` value (kernel param path readback is
   fine; e.g. 131072 = 2.0).
2. Reproduce Apple's index interpolation for that value → native `(GL,GP,GC,GQ,TSL,TSPR)`.
3. For slider f: build one curve dict `{Index:0, GL',GP',GC',GQ', TSL', TSPR'}`, wrap it
   in a 1-element CFArray, write it to `UserPointerAccelCurvesKey` on that device's
   pointer event service with `IOHIDServiceClientSetProperty` (full client). Setting
   Index=0 with a single-element array makes it independent of the current acceleration
   value (it is used verbatim; no interpolation because there is no next entry).
4. f=1: write an empty CFArray (or, equivalently, stop overriding and rebuild) → native.
5. f=0: write a negative acceleration value on the same service (raw −65536), which
   bypasses acceleration entirely (previous notes). If coming from f>0, also clear the
   user curves (empty array) to leave no stale shape if the filter rebuilds later.
6. Keep the original positive acceleration value to restore on quit; the app already
   snapshots kernel `HIDTrackpadAcceleration` for the disable path.

Expected debug-log proof for a curve write (verified):
```
Acceleration key:UserPointerAccelCurvesKey value:(...)
Pointer acceleration value 2.000000
acceleration 2.000000 resolution 400.000000 rate 67.000000
table index 0          <-- 0 = our single curve; baseline is table index 7
```
After clearing: `table index 7` (native fallback).

### Mice
- If the mouse's pointer event service exposes `HIDAccelCurves` (Apple-style devices and
  possibly most HID mice — it's the filter's first choice): use exactly the trackpad
  procedure (read curves, index-interpolate, blend, per-service write).
- If the service only has `HIDPointerAccelerationTable` (table-only mouse): **do not
  ship intermediate amounts yet.**
  - The table route cannot install a modified table (§2.2): transient property not
    visible, table not cached.
  - The parametric fallback would have to *approximate* the table baseline. Modelling
    Apple's compiled-in `defaultAccelTable` (102 bytes, 2 entries at acceleration 0 and
    1.0) with `CreateWithTable` at `HIDMouseAcceleration = 0.6875` gives a baseline whose
    gain in raw-count units is < 1 for slow movement (e.g. ≈0.23 at v=1, rising to
    ≈1.3 at v=80). Fitting our parametric family to a gain-domain blend of that baseline
    and identity gave poor results across TSL/TSPR/GQ sweeps:
    f=0.25 max err 0.143, f=0.50 0.286, f=0.75 0.429, f=0.95 0.543 (gain units) and
    min gains below 1 — i.e. intermediate settings could feel slower/speed-dependent in
    a way the blend is supposed to avoid, and we have no physical mouse on this machine
    to validate the baseline interpretation (resolution/report-rate/table units).
  - Recommended: for table-only mice expose only **Off (1:1)** and **System (100 %)**;
    enable the continuous slider for devices whose service exposes `HIDAccelCurves`.
    Revisit after a hardware test with an external mouse (`tapmeasure` rig in
    `Tools/Probe/` + a simple A/B-by-ear test): if the table baseline's real-world gain
    is measured, a fit can be produced then.
  - If a continuous slider must be shown for every mouse, an alternative is a
    CGEventTap gain layer (Accessibility permission required) — out of scope of the
    native path and not recommended for v1.

The two classes are independent: the user curves are set per *service*, so a trackpad
curve and a mouse curve can differ (and the cache is per filter instance). Global
kernel-param writes (IOHIDSetCFTypeParameter) can overwrite the per-service cached
curves on all services — reapply per class after anything that writes the global
trackpad/mouse acceleration values (e.g. System Settings tracking speed). See
`Notes/acceleration-research.md` §5 for the mixed-layer caveat.

---

## 7. Expected serialized ("ServiceFilterDebug") output for verification

`ServiceFilterDebug` (key string!) returns the first filter's serialization only; on the
built-in trackpad that is `IOHIDEventProcessorFilter`, not the pointer filter (verified:
the returned dict had `name = com.apple.iohid.IOHIDEventProcessorFilter`), so it cannot
be used as the pointer-accelerator oracle on this machine. Use the WindowServer debug log
instead. If you do get the pointer filter's serialize dict, expect for our single curve
(serialize() omits GainQuartic):

| f | Class | AccelIndex | GainLinear | GainCubic | GainParabolic | TangentSpeedLinear | TangentSpeedParabolicRoot |
|---|---|---|---|---|---|---|---|
| 0.00 | IOHIDParametricAcceleration | 0 | 45739 | 0 | 0 | 0 | 0 |
| 0.25 | IOHIDParametricAcceleration | 0 | 48394 | 9909 | 47514 | 458752 | 917504 |
| 0.50 | IOHIDParametricAcceleration | 0 | 51050 | 12484 | 67194 | 458752 | 917504 |
| 0.75 | IOHIDParametricAcceleration | 0 | 53705 | 14291 | 82296 | 458752 | 917504 |
| 1.00 (native selection, no user curves) | IOHIDParametricAcceleration | 131072 | 56361 | 15729 | 95027 | 458752 | 917504 |

(All values raw IOFixed = round(double*65536).)

Gain tables (filter-domain gain, raw passthrough = 1.0; trackpad baseline 2.0):

| v_std | 2 | 7 | 14 | 30 | 60 |
|---|---|---|---|---|---|
| f=0 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| f=0.25 | 2.584 | 6.573 | 9.451 | 8.801 | 6.823 |
| f=0.50 | 4.168 | 12.145 | 17.903 | 16.752 | 13.000 |
| f=0.75 | 5.752 | 17.718 | 26.354 | 24.703 | 19.176 |
| f=1 (native) | 7.337 | 23.291 | 34.805 | 32.654 | 25.352 |

(v_std 2 ≈ 3.6 in/s, 7 ≈ 12.5 in/s, 14 ≈ 25 in/s for a 120 Hz report-rate trackpad;
see `curve_math.py` for the conversion.)

Mouse (parametric variant) uses the same formula with the mouse's native curve and
acceleration value; no absolute table is given here because no mouse was attached.

---

## 8. Verification plan for the app (checklist)

1. Read/keep `kernel HIDTrackpadAcceleration` and `HIDMouseAcceleration` originals.
2. On slider change f>0: build curve (formula §4 + TSPR lookup §5), write it via full
   client `IOHIDServiceClientSetProperty(svc, "UserPointerAccelCurvesKey", cfArray)`,
   ensure the service's acceleration value is positive (restore the user's tracking
   speed value if Decelerate's 1:1 mode had set it negative earlier).
3. Dev verification: run `log stream --debug` and confirm the sequence
   `Acceleration key:UserPointerAccelCurvesKey`, `acceleration <value> resolution 400
   rate 67`, `table index 0` (or the index of your curve if multiple entries).
4. f=1: write empty array (or stop overriding) → log shows `table index 7` (trackpad) /
   table path for table-only devices.
5. f=0: negative acceleration value → log shows `Pointer acceleration (disabled)`.
6. Rebuild checks: write `HIDScrollAcceleration`/tracking-speed value and confirm
   `table index 0` persists (tested here); after clearing confirm native.
7. Restore on quit: original acceleration values + clear user curves; verify
   `Pointer acceleration (enabled)` with the original value and no stale curves.
8. Safety: no root/TCC/entitlements (same as the binary mechanism); never restart
   WindowServer; all writes are runtime-only (reset at logout/reboot).

---

## 9. Probe additions (Tools/Probe/)

- `curve_math.py` — Python reimplementation of Apple's parametric + table algorithms:
  `--analysis` (trackpad blend, tail strategies, monotonicity), `--mouse` (compiled-in
  default table model + parametric fit), default mode (curve dicts, gain tables,
  expected serialization). Used to generate every number in this note.
- `hidprobe` new commands: `get-id` / `get-id-raw` (full-client per-service reads),
  `write-data` (dump CFData property as hex), `write-array` (dump CFArray property as
  JSON), `param-*` (kernel param path), plus value syntax `data:<hex>`,
  `arrayjson:<json>`, `emptyarray` for per-service `set-id` writes.
- Evidence: `out/evidence-accel-amount.txt`, `out/trackpad-accel-amount-table.json`
  (full f table incl. raw coefficients), `out/trackpad-curves-service.json`,
  `out/trackpad-table-service.hex`.

---

## 10. Machine state / safety

All changes made during this task were restored:
`HIDTrackpadAcceleration = 131072 (2.0)`, `HIDMouseAcceleration = 45056 (0.6875)`,
`HIDPointerAcceleration = 45056`, `HIDUseLinearScalingMouseAcceleration = 0`,
`HIDScrollAcceleration = 20480`; trackpad service: original table bytes (verified
byte-identical), `UserPointerAccelCurvesKey` cleared (empty array → native fallback),
`HIDPointerAccelerationAlgorithm` back to Default(2). Live filter: `Pointer acceleration
(enabled) HIDTrackpadAcceleration:131072 ... 131072`, native curve selection
(`table index 7`). No WindowServer restart, no root, no defaults written.

GOTCHA for the app: filter-side `_property` caches persist after the writing process
exits (WindowServer owns them), so quitting Decelerate without clearing
`UserPointerAccelCurvesKey` leaves the blended curve in effect until logout/reboot or
until another client rewrites the property. Restore on quit is mandatory; also restore/
clear when the slider is at 100 % or the feature is off.

## 11. Open items / handoff

1. Mouse hardware test: attach an external mouse, check whether its service exposes
   `HIDAccelCurves` (then continuous slider works exactly). If table-only, keep
   binary-only until measured; `tapmeasure` can measure raw-vs-delivered gain.
2. Optional: confirm `kIOHIDUserPointerAccelCurvesKey` string from IOKit private headers
   (we only have the behavioural evidence + Apple source use; the literal
   "UserPointerAccelCurvesKey" is verified by the filter's own debug output).
3. User feel-test of 25/50/75 % on the trackpad; if the high-speed tail approximation is
   noticeable, tune the TSPR lookup (lower error at high v by increasing TSPR further,
   trading normal-range fidelity).
