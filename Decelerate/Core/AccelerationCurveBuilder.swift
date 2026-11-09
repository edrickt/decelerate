import Foundation

/// Builds custom pointer-acceleration curves and tables that blend natively
/// between macOS's own acceleration (`factor` = 1) and perfectly linear 1:1
/// movement (`factor` = 0).
///
/// The math mirrors Apple's `IOHIDPointerScrollFilter` /
/// `IOHIDParametricAcceleration` (see `Notes/acceleration-amount-research.md`):
///
///     gain(v) = GainLinear + GainParabolic²·v + GainCubic³·v² + GainQuartic⁴·v³
///
/// for the first segment. Blending the *gain* toward 1.0 therefore means
///
///     GainLinear' = 1 + f·(GainLinear − 1)
///     GainParabolic' = √f·GainParabolic
///     GainCubic' = ∛f·GainCubic
///     GainQuartic' = ⁴√f·GainQuartic
///
/// which is exact at both ends (f = 0 ⇒ gain 1 everywhere, f = 1 ⇒ macOS curve).
enum AccelerationCurveBuilder {
    /// IOFixed scale: one unit is 1/65536.
    static let fixedOne = 65_536

    // MARK: - Parametric curves

    static func blendedCurves(_ native: [[String: Int]], factor: Double) -> [[String: Int]] {
        let f = min(max(factor, 0), 1)
        return native.map { curve in
            blendedCurve(curve, factor: f)
        }
    }

    private static func blendedCurve(_ curve: [String: Int], factor f: Double) -> [String: Int] {
        let linear = value(curve, HIDCurveKey.gainLinear)
        let parabolic = value(curve, HIDCurveKey.gainParabolic)
        let cubic = value(curve, HIDCurveKey.gainCubic)
        let quartic = value(curve, HIDCurveKey.gainQuartic)

        var result = curve
        result[HIDCurveKey.gainLinear] = fixed(1.0 + f * (linear - 1.0))
        result[HIDCurveKey.gainParabolic] = fixed(sqrt(f) * parabolic)
        result[HIDCurveKey.gainCubic] = fixed(cbrt(f) * cubic)
        result[HIDCurveKey.gainQuartic] = fixed(quarticRoot(f) * quartic)

        // The parabolic-root tangent marks where macOS starts capping the
        // acceleration gain. Pushing it out as f→0 keeps the blended curve
        // monotonic instead of inheriting macOS's high-velocity gain drop.
        let root = value(curve, HIDCurveKey.tangentSpeedParabolicRoot)
        if root > 0, f > 0 {
            let scaled = min(root / f, 32_000.0)
            result[HIDCurveKey.tangentSpeedParabolicRoot] = fixed(scaled)
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
