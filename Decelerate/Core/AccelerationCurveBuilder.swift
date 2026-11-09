import Foundation

/// Builds custom pointer-acceleration curves and tables that blend natively
/// between macOS's own acceleration (`factor` = 1) and perfectly linear 1:1
/// movement (`factor` = 0).
///
/// The math mirrors Apple's `IOHIDPointerScrollFilter` /
/// `IOHIDParametricAcceleration` (see `Notes/acceleration-amount-research.md`):
///
///     multiplier(v) = kCursorScale · (GainLinear·v + (GainParabolic·v)²
///                                      + (GainCubic·v)³ + (GainQuartic·v)⁴)
///
/// for the first segment, where `kCursorScale = 96/67`. The filter's *gain*
/// (multiplier/v) is therefore scaled by `kCursorScale` too, so identity in the
/// parametric domain is `GainLinear = 1/kCursorScale = 67/96`, not 1.0 (the
/// simple linear-scaling path multiplies deltas directly, so raw passthrough is
/// gain 1.0 there). Blending the gain from identity (f = 0) to the device's
/// macOS curve (f = 1) is then
///
///     GainLinear' = (1 − f)/kCursorScale + f·GainLinear
///     GainParabolic' = √f·GainParabolic
///     GainCubic' = ∛f·GainCubic
///     GainQuartic' = ⁴√f·GainQuartic
///
/// with the native tangent breakpoints kept. Segments 1–2 are exact; the
/// high-velocity √ tail is approximated by scaling its breakpoint (see
/// `tailScale`) so the blended curve never decelerates below 1:1.
enum AccelerationCurveBuilder {
    /// IOFixed scale: one unit is 1/65536.
    static let fixedOne = 65_536
    /// Apple's cursor scale in the parametric acceleration domain
    /// (`multiplier()` returns `S(v) * 96/67`).
    static let cursorScale = 96.0 / 67.0
    /// `GainLinear` that produces a filter gain of exactly 1.0 (raw passthrough).
    static let identityLinearGain = 1.0 / cursorScale
    /// Below this factor the parametric curve family is numerically useless
    /// (and 0% uses the negative-sentinel path anyway).
    static let minimumCurveFactor = 0.01

    // MARK: - Parametric curves

    static func blendedCurves(_ native: [[String: Int]], factor: Double) -> [[String: Int]] {
        let f = min(max(factor, minimumCurveFactor), 1)
        return native.map { curve in
            blendedCurve(curve, factor: f)
        }
    }

    /// Keeps the high-velocity tail honest at small factors: the native
    /// parabolic-root breakpoint makes the √ segment kick in too early once the
    /// coefficients are heavily damped, which would make the tail decelerate.
    /// These factors (from the research) push it out just enough. Error vs. the
    /// ideal blend is < 0.3 gain units and the gain never drops below 1.
    private static func tailScale(_ f: Double) -> Double {
        let points: [(Double, Double)] = [
            (0.01, 3.15), (0.02, 2.20), (0.05, 1.50),
            (0.10, 1.25), (0.15, 1.15), (0.25, 1.00),
        ]
        guard f < points.last!.0 else { return 1.0 }
        guard let first = points.first else { return 1.0 }
        if f <= first.0 { return first.1 }
        for index in 1..<points.count {
            let (f1, s1) = points[index]
            let (f0, s0) = points[index - 1]
            if f <= f1 {
                let t = (f - f0) / (f1 - f0)
                return s0 + t * (s1 - s0)
            }
        }
        return 1.0
    }

    private static func blendedCurve(_ curve: [String: Int], factor f: Double) -> [String: Int] {
        let linear = value(curve, HIDCurveKey.gainLinear)
        let parabolic = value(curve, HIDCurveKey.gainParabolic)
        let cubic = value(curve, HIDCurveKey.gainCubic)
        let quartic = value(curve, HIDCurveKey.gainQuartic)

        var result = curve
        result[HIDCurveKey.gainLinear] = fixed((1 - f) * identityLinearGain + f * linear)
        result[HIDCurveKey.gainParabolic] = fixed(sqrt(f) * parabolic)
        result[HIDCurveKey.gainCubic] = fixed(cbrt(f) * cubic)
        result[HIDCurveKey.gainQuartic] = fixed(quarticRoot(f) * quartic)

        let root = value(curve, HIDCurveKey.tangentSpeedParabolicRoot)
        if root > 0 {
            result[HIDCurveKey.tangentSpeedParabolicRoot] = fixed(root * tailScale(f))
        }
        return result
    }

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
