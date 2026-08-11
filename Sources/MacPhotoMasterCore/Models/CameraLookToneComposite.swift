import Foundation

/// Composes the measured basis curves in `CameraLookToneCurves` into the one curve a frame was
/// actually rendered with, for the look visualiser (docs/SPEC.md groups 3-6).
///
/// Every rule below was measured off real frames rather than assumed — `scripts/README.md` has the
/// numbers:
///
/// - The three tone dials compose by **adding their deviations** from the identity. Serial
///   composition loses badly on two of the three pairs (11.46 and 10.28 rms against additive's
///   3.84). Additive is itself wrong by up to 8 levels in the upper midtones, accepted deliberately
///   because it changes neither which way the curve bends nor where it pivots.
/// - Picture Mode contrast is a **separate serial stage, applied first** — 0.46 rms against
///   Highlight +7, comfortably independent.
/// - Gradation **overrides contrast entirely**: under High Key the contrast dial is the identity to
///   1.2 levels where the same change under Normal moves 20.2, *and the maker note still records the
///   value the camera ignored*. So a populated `contrast` is not evidence the camera applied it.
/// - One table serves every Picture Mode (Monochrome against Colour Profile agrees to 0.1 of a
///   level), and one grey curve serves all three channels (per-channel spread collapses to 3.04
///   once the rig's white balance is neutral).
///
/// **Not measured, and assumed here:** how a Gradation preset combines with the tone dials. It is
/// applied as its own serial stage after them, which reuses the shape of the measured stages rather
/// than inventing a new one, but the rig came down before the pair could be shot.
public enum CameraLookToneComposite {
    /// The rendered curve, as an output level for each input level 0...255, or nil when there is
    /// nothing honest to draw.
    ///
    /// Nil covers two cases: a look that dialled nothing, and Gradation Auto, where the camera chose
    /// a curve per frame and recorded no trace of which one. Drawing the tone dials alone under Auto
    /// would show a curve the frame was not rendered with.
    public static func curve(for look: CameraLook) -> [Double]? {
        if look.gradationIsAuto { return nil }

        let dials = look.toneLevels.filter { $0.value != 0 }
        var contrast: [Double]?
        if !contrastIsSuppressed(look), let value = look.contrast, value != 0 {
            contrast = deviation(code: "Contrast", value: value)
        }
        var preset: [Double]?
        if let gradation = look.gradation {
            preset = CameraLookToneCurves.gradationPresets[gradation]
            if preset == nil { return nil }
        }

        let offsets = dials.compactMap { deviation(code: $0.code, value: $0.value) }
        guard offsets.count == dials.count else { return nil }
        guard !offsets.isEmpty || contrast != nil || preset != nil else { return nil }

        return (0...255).map { input in
            var level = Double(input)
            if let contrast { level += interpolate(contrast, at: level) }
            // Additive, so every dial reads its deviation at the *same* input, not in sequence.
            let tone = level
            for offset in offsets { level += interpolate(offset, at: tone) }
            if let preset { level += interpolate(preset, at: level) }
            return min(255, max(0, level))
        }
    }

    /// Whether the camera ignored the contrast dial, so the view can say so rather than draw it.
    /// True under every Gradation setting that is not Normal, Auto included.
    public static func contrastIsSuppressed(_ look: CameraLook) -> Bool {
        look.gradation != nil || look.gradationIsAuto
    }

    /// One dial's deviation curve, interpolating between the odd steps that were shot.
    ///
    /// The measured spacing is what makes straight-line interpolation defensible: Midtone reads
    /// 8.2, 24.7, 41.8 and 58.8 at +1/+3/+5/+7, so its steps sit 16.5, 17.1 and 17.0 apart.
    static func deviation(code: String, value: Int) -> [Double]? {
        guard let measured = CameraLookToneCurves.dials[code] else { return nil }
        if let exact = measured[value] { return exact }
        if value == 0 { return Array(repeating: 0, count: CameraLookToneCurves.knots.count) }

        // Bracket by magnitude on the dialled side, treating 0 as a measured all-zero curve.
        let step = value > 0 ? 1 : -1
        guard let above = measured[value + step] else { return nil }
        let below = measured[value - step] ?? Array(repeating: 0, count: above.count)
        return zip(below, above).map { ($0 + $1) / 2 }
    }

    /// A sampled curve read at an arbitrary input level, linear between knots.
    static func interpolate(_ samples: [Double], at input: Double) -> Double {
        let knots = CameraLookToneCurves.knots
        let clamped = min(Double(knots[knots.count - 1]), max(0, input))
        guard let upper = knots.firstIndex(where: { Double($0) >= clamped }) else { return 0 }
        if upper == 0 { return samples[0] }
        let low = Double(knots[upper - 1]), high = Double(knots[upper])
        let fraction = (clamped - low) / (high - low)
        return samples[upper - 1] + (samples[upper] - samples[upper - 1]) * fraction
    }
}
