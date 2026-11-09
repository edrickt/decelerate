import Foundation

/// Builds custom pointer-acceleration curves that blend natively between
/// macOS's own acceleration (`factor` = 1) and linear movement
/// (`factor` = 0), with an independent speed multiplier.
///
/// The math mirrors Apple's `IOHIDPointerScrollFilter` /
/// `IOHIDParametricAcceleration` (see `Notes/acceleration-amount-research.md`):
///
///     gain(v) = GainLinear + GainParabolic²·v + GainCubic³·v² + GainQuartic⁴·v³
///
/// for the first segment (device velocity is normalised by `resolution/rate`).
/// `GainLinear = 1.0` is the physical 1:1 identity; the fully accelerated path
/// with no curve installed produces the same movement, so 1.0 is the correct
/// zero-acceleration base. Blending from that identity (f = 0) to the device's
/// macOS curve (f = 1) is
///
///     GainLinear' = 1 + f·(GainLinear − 1)
///     GainParabolic' = √f·GainParabolic
///     GainCubic' = ∛f·GainCubic
///     GainQuartic' = ⁴√f·GainQuartic
///
/// and the whole curve is then scaled by the speed multiplier s the same way
/// (all coefficients scaled so that `gain'(v) = s·gain(v)`):
///
///     GainLinear' · s,  GainParabolic' · √s,  GainCubic' · ∛s,  GainQuartic' · ⁴√s
///
/// Segments 1–2 are exact; the high-velocity √ tail is approximated by scaling
/// its breakpoint (see `tailScale`) so the blended curve never decelerates below
/// the requested speed.
enum AccelerationCurveBuilder {
    /// IOFixed scale: one unit is 1/65536.
    static let fixedOne = 65_536
    /// Below this factor the curve is exactly linear (f = 0 is handled directly).
    static let minimumCurveFactor = 0.0

    // MARK: - Curves

    static func curves(
        _ native: [[String: Int]],
        factor: Double,
        speed: Double
    ) -> [[String: Int]] {
        let f = min(max(factor, 0), 1)
        let s = min(max(speed, 0.1), 8)
        if f <= 0.005 {
            return native.map { constantGainCurve(index: $0[HIDCurveKey.index] ?? 0, gain: s) }
        }
        return native.map { curve in
            blendedCurve(curve, factor: f, speed: s)
        }
    }

    private static func constantGainCurve(index: Int, gain: Double) -> [String: Int] {
        [
            HIDCurveKey.index: index,
            HIDCurveKey.gainLinear: fixed(gain),
            HIDCurveKey.gainParabolic: 0,
            HIDCurveKey.gainCubic: 0,
            HIDCurveKey.gainQuartic: 0,
            HIDCurveKey.tangentSpeedLinear: 0,
            HIDCurveKey.tangentSpeedParabolicRoot: 0,
        ]
    }

    private static func blendedCurve(
        _ curve: [String: Int],
        factor f: Double,
        speed s: Double
    ) -> [String: Int] {
        let linear = value(curve, HIDCurveKey.gainLinear)
        let parabolic = value(curve, HIDCurveKey.gainParabolic)
        let cubic = value(curve, HIDCurveKey.gainCubic)
        let quartic = value(curve, HIDCurveKey.gainQuartic)

        // 1. Blend the speed-dependent part of the gain toward zero (f = 0 ⇒
        //    constant gain 1.0, f = 1 ⇒ the device's own curve).
        let blendedLinear = 1.0 + f * (linear - 1.0)
        let blendedParabolic = sqrt(f) * parabolic
        let blendedCubic = cbrt(f) * cubic
        let blendedQuartic = quarticRoot(f) * quartic

        // 2. Scale the entire gain by the speed multiplier.
        let rootSpeed = sqrt(s)
        var result = curve
        result[HIDCurveKey.gainLinear] = fixed(blendedLinear * s)
        result[HIDCurveKey.gainParabolic] = fixed(blendedParabolic * rootSpeed)
        result[HIDCurveKey.gainCubic] = fixed(blendedCubic * cbrt(s))
        result[HIDCurveKey.gainQuartic] = fixed(blendedQuartic * quarticRoot(s))

        let root = value(curve, HIDCurveKey.tangentSpeedParabolicRoot)
        if root > 0 {
            result[HIDCurveKey.tangentSpeedParabolicRoot] = fixed(root * tailScale(f, speed: s))
        }
        return result
    }

    /// Keeps the high-velocity tail correct at small factors: the native
    /// parabolic-root breakpoint makes the √ segment kick in too early once the
    /// coefficients are heavily damped, which would make the tail decelerate.
    /// These factors (from the research) push it out just enough.
    private static func tailScale(_ f: Double, speed: Double) -> Double {
        // The breakpoint is a velocity; raising the speed multiplier makes the
        // curve reach higher velocity values, so push the tail out proportionally.
        let speedScale = max(1.0, speed)
        let points: [(Double, Double)] = [
            (0.01, 3.15), (0.02, 2.20), (0.05, 1.50),
            (0.10, 1.25), (0.15, 1.15), (0.25, 1.00),
        ]
        var base: Double
        if f >= (points.last?.0 ?? 0.25) {
            base = 1.0
        } else if let first = points.first, f <= first.0 {
            base = first.1
        } else {
            base = 1.0
            for index in 1..<points.count {
                let (f1, s1) = points[index]
                let (f0, s0) = points[index - 1]
                if f <= f1 {
                    let t = (f - f0) / (f1 - f0)
                    base = s0 + t * (s1 - s0)
                    break
                }
            }
        }
        return base * speedScale
    }

    // MARK: - Helpers

    private static func fixed(_ value: Double) -> Int {
        Int((value * Double(fixedOne)).rounded())
    }

    private static func value(_ curve: [String: Int], _ key: String) -> Double {
        Double(curve[key] ?? 0) / Double(fixedOne)
    }

    private static func cbrt(_ value: Double) -> Double {
        value <= 0 ? 0 : pow(value, 1.0 / 3.0)
    }

    private static func quarticRoot(_ value: Double) -> Double {
        value <= 0 ? 0 : pow(value, 0.25)
    }
}
