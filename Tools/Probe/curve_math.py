#!/usr/bin/env python3
"""Source-derived math for Decelerate's continuous acceleration amount.

Reimplements Apple's IOHIDPointerScrollFilter pointer acceleration pipeline exactly as
published in IOHIDFamily (IOHIDEventSystemPlugIns/IOHIDAccelerationAlgorithm.cpp,
IOHIDAcceleration.cpp, IOHIDPointerScrollFilter.cpp) and derives the blend formula for an
"acceleration amount" f in [0,1].

Units / constants (straight from the source):
  * curve parameters (GainLinear, GainParabolic, GainCubic, GainQuartic) are IOFixed:
    raw / 65536.  They are coefficients in standardized speed units.
  * tangent speeds are also IOFixed, in the same standardized speed units.
  * the filter standardizes velocity:  v_std = v_counts_per_event / (resolution/rate)
    with resolution = pointer resolution in dpi (IOFixed 400 here means 400.0) and
    rate = FRAME_RATE = 67.0 (constant in the source, not the device report rate).
  * the algorithm's multiplier() returns accelerated_speed * kCursorScale,
    kCursorScale = 96/67.  The filter's applied gain is multiplier(v)/v.
  * therefore the parametric curve S(v) produces gain g(v) = kCursorScale * S(v)/v,
    and a true 1:1 curve needs GainLinear = 1/kCursorScale = 67/96 (not 1.0!).

Segments (source comments + code):
  1) v <= TSL:              S(v) = GL*v + (GP*v)^2 + (GC*v)^3 + (GQ*v)^4
  2) TSL < v <= TSPR:       S(v) = m0*v + b0, tangent line of segment 1 at TSL
  3) v > TSPR:              S(v) = sqrt(m1*v + b1), tangent of segment 2 at TSPR
  special cases: TSL==0 means only segments 1 and 3 (root used as tangent point);
                 TSPR==0 means only segments 1 and 2; both 0 means segment 1 only.
"""

import json
import math
import sys

KC = 96.0 / 67.0          # kCursorScale
RESOLUTION = 400.0        # HIDPointerResolution for the internal trackpad (IOFixed 400)
FRAME_RATE = 67.0         # FRAME_RATE constant used by the filter

# 10 curves from HIDAccelCurves of the built-in trackpad (AppleMultitouchDevice 0x1000bf484 /
# AppleMultitouchTrackpadHIDEventDriver 0x100000900), captured read-only from IORegistry.
TRACKPAD_CURVES = [
    dict(Index=0,      GL=65536, GP=0,     GC=0,     GQ=0, TSL=484966, TSPR=1376256),
    dict(Index=8192,   GL=64881, GP=32768, GC=5243,  GQ=0, TSL=478413, TSPR=1310720),
    dict(Index=32768,  GL=64225, GP=43254, GC=6554,  GQ=0, TSL=471859, TSPR=1245184),
    dict(Index=45056,  GL=62915, GP=54395, GC=7864,  GQ=0, TSL=465306, TSPR=1179648),
    dict(Index=57344,  GL=61604, GP=65536, GC=9830,  GQ=0, TSL=458752, TSPR=1114112),
    dict(Index=65536,  GL=60293, GP=75366, GC=11796, GQ=0, TSL=458752, TSPR=1048576),
    dict(Index=98304,  GL=58327, GP=85197, GC=13763, GQ=0, TSL=458752, TSPR=983040),
    dict(Index=131072, GL=56361, GP=95027, GC=15729, GQ=0, TSL=458752, TSPR=917504),
    dict(Index=163840, GL=54395, GP=108790, GC=18350, GQ=0, TSL=458752, TSPR=851968),
    dict(Index=196608, GL=65536, GP=123208, GC=23593, GQ=0, TSL=458752, TSPR=786432),
]

FIXED = 65536.0


def curve_from_raw(d):
    return dict(
        Index=d["Index"] / FIXED,
        GL=d["GL"] / FIXED,
        GP=d["GP"] / FIXED,
        GC=d["GC"] / FIXED,
        GQ=d["GQ"] / FIXED,
        TSL=d["TSL"] / FIXED,
        TSPR=d["TSPR"] / FIXED,
    )


def isValid(c):
    return any(c[k] != 0 for k in ("GL", "GP", "GC", "GQ"))


def select_curve(curves, accel_index):
    """IOHIDParametricAcceleration::CreateWithParameters curve selection/interpolation.
    `curves` are dicts with numeric fields (Index, GL, GP, GC, GQ, TSL, TSPR)."""
    valid = [c for c in curves if isValid(c)]
    if not valid or accel_index < 0:
        return None
    current = 0
    for i, c in enumerate(valid):
        if accel_index >= c["Index"]:
            current = i
    out = dict(valid[current])
    if (valid[current]["Index"] < accel_index) and (current + 1) < len(valid):
        nxt = valid[current + 1]
        ratio = (accel_index - valid[current]["Index"]) / (nxt["Index"] - valid[current]["Index"])
        for k in ("Index", "GL", "GP", "GC", "GQ", "TSL", "TSPR"):
            out[k] = valid[current][k] + ratio * (nxt[k] - valid[current][k])
    return out


class Parametric:
    """Exact reimplementation of IOHIDParametricAcceleration (source semantics)."""

    def __init__(self, c, resolution=RESOLUTION, rate=FRAME_RATE):
        self.c = c
        self.device_scale = resolution / rate   # resolution_/rate_
        # tangent construction, verbatim from CreateWithParameters
        self.tangent = [float("inf"), float("inf")]
        self.m = [0.0, 0.0]
        self.b = [0.0, 0.0]
        self.tsl = c["TSL"]
        self.tspr = c["TSPR"]
        if self.tsl != 0:
            y0 = (c["GL"] * self.tsl
                  + (c["GP"] * self.tsl) ** 2
                  + (c["GC"] * self.tsl) ** 3
                  + (c["GQ"] * self.tsl) ** 4)
            self.m[0] = (c["GL"]
                         + 2 * self.tsl * c["GP"] ** 2
                         + 3 * self.tsl ** 2 * c["GC"] ** 3
                         + 4 * self.tsl ** 3 * c["GQ"] ** 4)
            self.b[0] = y0 - self.m[0] * self.tsl
            self.tangent[0] = self.tsl
            if self.tspr != 0:
                y1 = self.m[0] * self.tspr + self.b[0]
                self.m[1] = 2 * y1 * self.m[0]
                self.b[1] = y1 ** 2 - self.m[1] * self.tspr
                self.tangent[1] = self.tspr
        elif self.tspr != 0:
            y0 = (c["GL"] * self.tspr
                  + (c["GP"] * self.tspr) ** 2
                  + (c["GC"] * self.tspr) ** 3
                  + (c["GQ"] * self.tspr) ** 4)
            self.m[1] = (c["GL"]
                         + 2 * self.tspr * c["GP"] ** 2
                         + 3 * self.tspr ** 2 * c["GC"] ** 3
                         + 4 * self.tspr ** 3 * c["GQ"] ** 4)
            self.b[1] = y0 ** 2 - self.m[1] * self.tspr
            self.tangent[0] = self.tspr

    def output_speed(self, v_std):
        """S(v): accelerated speed in standardized units (without kCursorScale)."""
        v = v_std
        if v <= self.tangent[0]:
            return (self.c["GL"] * v
                    + (self.c["GP"] * v) ** 2
                    + (self.c["GC"] * v) ** 3
                    + (self.c["GQ"] * v) ** 4)
        elif v <= self.tangent[1] and self.tangent[0] == self.tsl:
            return self.m[0] * v + self.b[0]
        else:
            val = self.m[1] * v + self.b[1]
            return math.sqrt(max(val, 0.0))

    def gain(self, v_std):
        """Applied pointer gain = output/in for a given standardized velocity."""
        if v_std <= 0:
            return KC * self.c["GL"]
        return KC * self.output_speed(v_std) / v_std


def blend(native, f):
    """Continuous acceleration-amount curve.
    Desired: gain_f(v) = (1-f)*1 + f*gain_native(v),
             equivalently S_f(v) = (1-f)*(v/KC) + f*S_native(v)
    Representable exactly by scaling coefficients:
      GL_f = (1-f)/KC + f*GL
      GP_f = sqrt(f)*GP,  GC_f = f^(1/3)*GC,  GQ_f = f^(1/4)*GQ
      TSL_f = TSL, TSPR_f = TSPR (breakpoints unchanged)
    Segments 1 and 2 are then an exact blend of the native curve with the identity line.
    Segment 3 is the sqrt curve tangent-matched at TSPR (the only approximation).
    """
    if f <= 0:
        return dict(Index=0, GL=1.0 / KC, GP=0.0, GC=0.0, GQ=0.0, TSL=0.0, TSPR=0.0)
    if f >= 1:
        return dict(native, Index=0)
    root = {"GL": (1 - f) / KC + f * native["GL"],
            "GP": math.sqrt(f) * native["GP"],
            "GC": f ** (1.0 / 3.0) * native["GC"],
            "GQ": f ** 0.25 * native["GQ"],
            "TSL": native["TSL"],
            "TSPR": native["TSPR"],
            "Index": 0}
    return root


def ideal_gain(native_alg, f, v):
    return (1 - f) + f * native_alg.gain(v)


def to_fixed(x):
    return int(round(x * FIXED))


def curve_dict_fixed(c):
    """The CFDictionary we would put inside HIDUserPointerAccelCurves (raw IOFixed ints)."""
    return {
        "HIDAccelIndex": to_fixed(c["Index"]),
        "HIDAccelGainLinear": to_fixed(c["GL"]),
        "HIDAccelGainParabolic": to_fixed(c["GP"]),
        "HIDAccelGainCubic": to_fixed(c["GC"]),
        "HIDAccelGainQuartic": to_fixed(c["GQ"]),
        "HIDAccelTangentSpeedLinear": to_fixed(c["TSL"]),
        "HIDAccelTangentSpeedParabolicRoot": to_fixed(c["TSPR"]),
    }


def main():
    curves = [curve_from_raw(c) for c in TRACKPAD_CURVES]
    # The machine's current trackpad setting HIDTrackpadAcceleration = 131072 = 2.0
    accel_value = 131072 / FIXED
    native = select_curve(curves, accel_value)
    nat = Parametric(native)
    print(f"# baseline: trackpad, HIDTrackpadAcceleration raw 131072 = {accel_value}")
    print("# selected native curve (interpolated by Index):")
    for k in ("Index", "GL", "GP", "GC", "GQ", "TSL", "TSPR"):
        print(f"#   {k:5s} = {native[k]:12.8f}   (raw {to_fixed(native[k])})")
    print(f"# deviceScale=resolution/rate={nat.device_scale:.6f}  kCursorScale={KC:.8f}")
    print()

    # Sanity: native gain at sample standardized velocities.
    print("## Native (f=1) gain g(v) at standardized velocities")
    vs = [0.5, 1, 2, 4, 7, 10, 14, 20, 30, 50, 80]
    print("v_std  " + "  ".join(f"{v:7.2f}" for v in vs))
    print("g_nat  " + "  ".join(f"{nat.gain(v):7.3f}" for v in vs))
    print()

    # Rebuild each blended curve from its own coefficients (as the filter will) and
    # compare against the ideal blend.
    print("## Blend check: rebuilt-from-coefficients vs ideal (1-f)+f*g_native")
    print("f      max|err| over v in [0.01,80]   at v   g(v)@v=2   g(v)@v=7   g(v)@v=14  g(v)@v=30")
    for f in (0.1, 0.25, 0.5, 0.75, 0.9, 1.0):
        blendc = blend(native, f)
        alg = Parametric(blendc)
        maxerr, atv = 0.0, 0.0
        for i in range(1, 8000):
            v = i / 100.0
            err = abs(alg.gain(v) - ideal_gain(nat, f, v))
            if err > maxerr:
                maxerr, atv = err, v
        print(f"{f:<5.2f}  {maxerr:<10.6g}                {atv:<7.2f} "
              f"{alg.gain(2):9.4f} {alg.gain(7):9.4f} {alg.gain(14):9.4f} {alg.gain(30):9.4f}")
    print()

    # f=0 identity proof
    ident = Parametric(blend(native, 0.0))
    print("## f=0 identity curve check (GL = 1/kCursorScale = 67/96)")
    print("f=0 curve fixed dict:", curve_dict_fixed(blend(native, 0.0)))
    errs = [abs(ident.gain(v) - 1.0) for v in [0.01, 0.1, 1, 7, 14, 30, 80, 500]]
    print(f"max |gain-1| = {max(errs):.3e}  (expect ~0)")
    print()

    # Monotonicity in v: output speed must be strictly increasing (no reversed movement).
    print("## Monotonicity of output speed S_f(v) and of gain in f")
    for f in (0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0):
        alg = Parametric(blend(native, f))
        prev = -1.0
        mono = True
        for i in range(0, 20000):
            v = i / 200.0
            s = alg.output_speed(v)
            if s < prev - 1e-12:
                mono = False
                break
            prev = s
        # pointwise monotone in f? blend is a convex combination by construction
        print(f"f={f:<4.2f} S(v) monotonic in v: {mono}")
    print()

    # Gain=1 crossing of the native curve (where native would decelerate below 1:1)
    print("## Native gain crossing 1.0 (deceleration region) for several acceleration settings")
    for av in (0.6875, 1.0, 1.5, 2.0, 2.5, 3.0):
        c = select_curve(curves, av)
        a = Parametric(c)
        cross = None
        v = 0.5
        while v < 500:
            if a.gain(v) < 1.0:
                cross = v
                break
            v += 0.25
        gmax = max(a.gain(x / 10.0) for x in range(1, 8000))
        print(f"accel={av:<6} g(2)={a.gain(2):6.3f} g(7)={a.gain(7):6.3f} "
              f"max g={gmax:6.3f}  first v where g<1: {cross if cross else '>500'}")
    print()

    # The curve we would actually write to HIDUserPointerAccelCurves for sample f.
    print("## HIDUserPointerAccelCurves entries (raw IOFixed ints) for sample f")
    for f in (0.0, 0.25, 0.5, 0.75, 1.0):
        c = blend(native, f)
        print(f"f={f:<4.2f} {curve_dict_fixed(c)}")
    print()

    # Expected filter serialize() output for each sample f (verification oracle).
    print("## Expected Serialize / ServiceFilterDebug output for the pointer accelerator")
    print("# (Class IOHIDParametricAcceleration; serialize() omits GainQuartic)")
    for f in (0.0, 0.25, 0.5, 0.75, 1.0):
        c = blend(native, f)
        print(f"f={f:<4.2f} Class=IOHIDParametricAcceleration AccelIndex={to_fixed(c['Index'])} "
              f"GainLinear={to_fixed(c['GL'])} GainCubic={to_fixed(c['GC'])} "
              f"GainParabolic={to_fixed(c['GP'])} "
              f"TangentSpeedLinear={to_fixed(c['TSL'])} "
              f"TangentSpeedParabolicRoot={to_fixed(c['TSPR'])}")
    print()

    # Physical-speed mapping table (needs device report rate).
    print("## Standardized v <-> physical speed (for intuition)")
    print("# v_std = counts/event / (400/67); counts/event = v*400/67")
    print("# finger speed in/s = counts/event * report_hz / 400")
    for v in (1, 2, 4, 7, 14, 30, 50):
        counts = v * RESOLUTION / FRAME_RATE
        print(f"v_std={v:5.2f}  counts/event={counts:8.2f}  "
              f"@120Hz={counts * 120 / RESOLUTION:7.2f} in/s  @67Hz={counts * 67 / RESOLUTION:7.2f} in/s")




def gain_error_stats(alg, nat, f, vmax=150.0, step=0.05):
    maxerr, atv = 0.0, 0.0
    v = step
    while v <= vmax:
        err = abs(alg.gain(v) - ideal_gain(nat, f, v))
        if err > maxerr:
            maxerr, atv = err, v
        v += step
    return maxerr, atv


def optimized_tspr(native, nat, f, vmax=150.0):
    """Pick TSPR_f (keeping TSL_native) that minimizes max |gain - ideal| over (0, vmax].
    Returns (tspr, maxerr, atv)."""
    best = None
    base = native["TSPR"] if native["TSL"] > 0 else 0.0
    if base <= 0:
        return native["TSPR"], 0.0, 0.0
    for k in range(0, 121):
        scale = 1.0 + k * 0.05          # 1.00 .. 7.00 x native TSPR
        c = blend(native, f)
        c["TSL"] = native["TSL"]
        c["TSPR"] = base * scale
        alg = Parametric(c)
        maxerr, atv = gain_error_stats(alg, nat, f, vmax=vmax)
        if best is None or maxerr < best[1]:
            best = (c["TSPR"], maxerr, atv)
    return best


def analysis():
    curves = [curve_from_raw(c) for c in TRACKPAD_CURVES]
    native = select_curve(curves, 2.0)
    nat = Parametric(native)
    print("## Scheme A: keep native breakpoints (TSL, TSPR unchanged)")
    print("f     max|gain err|@vmax=150   at v     min gain in [0,150]")
    for f in (0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99):
        alg = Parametric(blend(native, f))
        err, atv = gain_error_stats(alg, nat, f)
        ming = min(alg.gain(x / 10.0) for x in range(1, 1501))
        print(f"{f:<5.2f} {err:<24.6f} {atv:<8.2f} {ming:8.4f}")
    print()
    print("## Scheme B: per-f optimized TSPR (TSL kept native), vmax=150")
    print("f     TSPR_scale  TSPR(raw)   raw int   max|gain err|   at v")
    rows = {}
    for f in (0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99):
        tspr, err, atv = optimized_tspr(native, nat, f)
        scale = tspr / native["TSPR"]
        rows[f] = (tspr, err)
        print(f"{f:<5.2f} {scale:<11.3f} {tspr:<11.4f} {to_fixed(tspr):<9d} {err:<16.6f} {atv:6.2f}")
    print()
    print("## Scheme A vs B: gain at fixed v for sample f (ideal in parentheses)")
    for f in (0.1, 0.25, 0.5, 0.75):
        a = Parametric(blend(native, f))
        t = rows.get(f, (native["TSPR"], 0))[0]
        cb = blend(native, f); cb["TSPR"] = t
        b = Parametric(cb)
        line = f"f={f:<4.2f}"
        for v in (7, 14, 30, 60, 100, 150):
            ideal = ideal_gain(nat, f, v)
            line += f"  v{v}: A={a.gain(v):6.2f} B={b.gain(v):6.2f} ideal={ideal:6.2f}"
        print(line)
    print()
    print("## Monotonicity in f (fixed v): gain_f must increase from 1 to g_native")
    for v in (2, 7, 14, 30, 60):
        gs = [Parametric(blend(native, f)).gain(v) for f in (0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0)]
        mono = all(gs[i] <= gs[i + 1] + 1e-9 for i in range(len(gs) - 1))
        print(f"v={v:<4} monotone: {mono}  g: " + " ".join(f"{g:.2f}" for g in gs))
    print()
    print("## f=0 with native breakpoints is NOT identity at high v (why f=0 uses TSL=TSPR=0)")
    c0 = blend(native, 0.0)
    for label, cc in (("TSL=TSPR=0 (exact)", c0),
                      ("native TSL/TSPR", dict(c0, TSL=native["TSL"], TSPR=native["TSPR"]))):
        a = Parametric(cc)
        print(f"  {label}: gain(30)={a.gain(30):.4f} gain(100)={a.gain(100):.4f}")
    print()
    print("## Breakpoint/coefficient continuity proof by construction")
    print("  m0_f = (1-f)/KC + f*m0_n     b0_f = f*b0_n")
    print("  y1_f = (1-f)*TSPR/KC + f*y1_n  m1_f = 2*y1_f*m0_f  b1_f = y1_f^2 - m1_f*TSPR")
    print("  -> segments 1&2 are exact; segment 3 is tangent-matched sqrt (approximation).")


if __name__ == "__main__" and "--analysis" in sys.argv:
    analysis()





# =====================================================================================
# Mouse fallback: Apple's table algorithm (CreateWithTable) + parametric fit
# =====================================================================================

import struct


def parse_accel_table(data: bytes):
    """Parse ACCEL_TABLE (big-endian fields, signature raw). Mirrors
    IOHIDAccelerationTable.cpp + IOHIDAccelerationTable.hpp."""
    scale = struct.unpack(">i", data[0:4])[0] / FIXED
    signature = struct.unpack("<I", data[4:8])[0]  # signature_ read raw on LE host
    count = struct.unpack(">H", data[8:10])[0]
    entries = []
    off = 10
    for _ in range(count):
        accel = struct.unpack(">i", data[off:off + 4])[0] / FIXED
        n = struct.unpack(">H", data[off + 4:off + 6])[0]
        pts = []
        p = off + 6
        for _ in range(n):
            x = struct.unpack(">i", data[p:p + 4])[0] / FIXED
            y = struct.unpack(">i", data[p + 4:p + 8])[0] / FIXED
            pts.append((x, y))
            p += 8
        entries.append(dict(accel=accel, points=pts))
        off = p
    return dict(scale=scale, signature=signature, entries=entries)


def table_multiplier(entries, accel, resolution=RESOLUTION, rate=FRAME_RATE):
    """iohidtableacceleration::createwithtable + multiplier(), returns f(v)."""
    hi_ = entries[0]
    lo_ = hi_
    hi = lo = None
    for i, e in enumerate(entries):
        lo = hi_
        hi = e
        hi_ = e
        if accel <= e["accel"]:
            if accel == e["accel"]:
                lo = e
            break
    if hi is None:
        hi = entries[-1]
        lo = hi
    fset = {}
    if hi is lo or accel > hi["accel"]:
        scale_ = (accel + 1) / (hi["accel"] + 1)
        for (x, y) in hi["points"]:
            fset[(x, y * scale_)] = True
    else:
        ratio = (accel - lo["accel"]) / (hi["accel"] - lo["accel"])

        def interpolate(loE, hiE, r):
            ph0 = (0.0, 0.0)
            ph1 = hiE["points"][0]
            hindex = 0
            for (x, y) in loE["points"]:
                while x > ph1[0] and hindex < len(hiE["points"]) - 1:
                    ph0 = ph1
                    hindex += 1
                    ph1 = hiE["points"][hindex]
                m = 0.0 if ph1[0] == ph0[0] else (ph1[1] - ph0[1]) / (ph1[0] - ph0[0])
                b = ph1[1] - m * ph1[0]
                liney = m * x + b
                outy = min(y, liney) + abs(y - liney) * r
                fset[(x, outy)] = True
        interpolate(lo, hi, ratio)
        interpolate(hi, lo, ratio)
    pts = sorted(fset.keys())
    segments = []
    p0 = (0.0, 0.0)
    for (x, y) in pts:
        p1 = (x * resolution / rate, y * KC)
        if p1[0] != p0[0]:
            m = (p1[1] - p0[1]) / (p1[0] - p0[0])
            b = p1[1] - m * p1[0]
            segments.append((m, b, p1[0]))
        p0 = p1

    def mult(v):
        for (m, b, x) in segments:
            if v <= x:
                return m * v + b
        m, b, _x = segments[-1]
        return m * v + b
    return mult


def mouse_gain_table(default_table_bytes, accel_value):
    entries = parse_accel_table(default_table_bytes)["entries"]
    mult = table_multiplier(entries, accel_value)
    def gain(v):
        if v <= 0:
            return 0.0
        return mult(v) / v
    return gain


def fit_parametric(target_gain, f, tsl=7.0, tspr=14.0, fit_max=7.0):
    """Least-squares fit of the f1 polynomial (GL,GP,GC) to target S(v)=v*g(v)/KC
    over [0.2, fit_max], then evaluate the rebuilt algorithm."""
    import itertools
    xs, ys = [], []
    v = 0.2
    while v <= fit_max:
        target = 1.0 + f * (target_gain(v) - 1.0)
        xs.append(v)
        ys.append(v * target / KC)
        v += 0.02
    # S = GL*v + GP^2*v^2 + GC^3*v^3, linear in u=[GL,GP^2,GC^3]
    A = [[x, x * x, x ** 3] for x in xs]
    # normal equations
    N = [[sum(A[k][i] * A[k][j] for k in range(len(xs))) for j in range(3)] for i in range(3)]
    rhs = [sum(A[k][i] * ys[k] for k in range(len(xs))) for i in range(3)]
    # solve 3x3
    import copy
    M = [row[:] + [rhs[i]] for i, row in enumerate(N)]
    for c in range(3):
        p = max(range(c, 3), key=lambda r: abs(M[r][c]))
        M[c], M[p] = M[p], M[c]
        if abs(M[c][c]) < 1e-12:
            return None
        for r in range(3):
            if r != c:
                factor = M[r][c] / M[c][c]
                for k in range(c, 4):
                    M[r][k] -= factor * M[c][k]
    u = [M[i][3] / M[i][i] for i in range(3)]
    GL, GP, GC = u[0], math.sqrt(max(u[1], 0)), (max(u[2], 0)) ** (1.0 / 3.0)
    c = dict(Index=0, GL=max(GL, 0.0), GP=GP, GC=GC, GQ=0.0, TSL=tsl, TSPR=tspr)
    alg = Parametric(c)
    maxerr, atv, ming = 0.0, 0.0, 1e9
    v = 0.05
    while v <= 150:
        ideal = 1.0 + f * (target_gain(v) - 1.0)
        g = alg.gain(v)
        if abs(g - ideal) > maxerr:
            maxerr, atv = abs(g - ideal), v
        ming = min(ming, g)
        v += 0.05
    return dict(curve=curve_dict_fixed(c), GL=GL, GP=GP, GC=GC, maxerr=maxerr, atv=atv,
                ming=ming, alg=alg)


def mouse_analysis():
    data = open("/tmp/default-table.bin", "rb").read()
    parsed = parse_accel_table(data)
    print("## Mouse: compiled-in defaultAccelTable parsed")
    print("scale", parsed["scale"], "signature", hex(parsed["signature"]), "entries:",
          [(e["accel"], len(e["points"])) for e in parsed["entries"]])
    g = mouse_gain_table(data, 45056 / FIXED)   # HIDMouseAcceleration default 0.6875
    print("native mouse gain at HIDMouseAcceleration=0.6875:")
    for v in (0.5, 1, 2, 4, 7, 10, 14, 20, 30, 50, 80, 120):
        print(f"  v={v:<5} g={g(v):8.4f}")
    print()
    print("## Parametric fit of blended curves (TSL=7, TSPR=14), target = 1+f*(mouse_native-1)")
    for f in (0.25, 0.5, 0.75):
        r = fit_parametric(g, f)
        print(f"f={f:<4.2f} maxerr={r['maxerr']:.4f}@{r['atv']:.1f} minG={r['ming']:.3f} "
              f"GL={r['GL']:.5f} GP={r['GP']:.5f} GC={r['GC']:.5f}")
        print("   curve:", r["curve"])
    print()
    print("## Trackpad: native gain (parametric, accel 2.0) and blended gain at sample v")
    curves = [curve_from_raw(c) for c in TRACKPAD_CURVES]
    native = select_curve(curves, 2.0)
    nat = Parametric(native)
    for f in (0.0, 0.25, 0.5, 0.75, 1.0):
        alg = Parametric(blend(native, f))
        print(f"f={f:<4.2f} " + "  ".join(f"v{v}:{alg.gain(v):6.3f}" for v in (2, 7, 14, 30, 60)))


if __name__ == "__main__":
    if "--mouse" in sys.argv:
        mouse_analysis()
    elif "--analysis" in sys.argv:
        analysis()
    else:
        main()
