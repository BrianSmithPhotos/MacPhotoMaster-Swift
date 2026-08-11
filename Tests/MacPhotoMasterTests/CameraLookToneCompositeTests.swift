import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Guards the composition rules in `CameraLookToneComposite`, which are measured results rather
/// than arithmetic (`scripts/README.md`) — so the tests that matter are the ones asserting a rule
/// the code could plausibly get wrong in either direction: additive rather than serial for the
/// three tone dials, serial for contrast, and contrast suppressed whenever Gradation is not Normal.
final class CameraLookToneCompositeTests: XCTestCase {
    private func look(
        tone: [(String, Int)] = [],
        contrast: Int? = nil,
        gradation: String? = nil,
        gradationIsAuto: Bool = false
    ) -> CameraLook {
        var look = CameraLook()
        look.toneLevels = tone.map { CameraLook.Slider(code: $0.0, value: $0.1) }
        look.contrast = contrast
        look.gradation = gradation
        look.gradationIsAuto = gradationIsAuto
        return look
    }

    // MARK: - Reproducing what was measured

    /// A single dial has to come back out as the curve that went in, or nothing downstream means
    /// anything. Highlight +7 measured +29.71 at input 208, which is one of its knots.
    func testASingleDialReproducesItsMeasuredCurve() throws {
        let curve = try XCTUnwrap(CameraLookToneComposite.curve(for: look(tone: [("HL", 7)])))
        XCTAssertEqual(curve[208], 208 + 29.71, accuracy: 0.01)
    }

    /// Highlight is measured as acting only in the upper half — flat to under a level below input
    /// 128 — so a Highlight-only look must leave the shadows alone.
    func testHighlightLeavesTheShadowsAlone() throws {
        let curve = try XCTUnwrap(CameraLookToneComposite.curve(for: look(tone: [("HL", 7)])))
        for input in 0...96 {
            XCTAssertEqual(curve[input], Double(input), accuracy: 1.0)
        }
    }

    // MARK: - The composition rules

    /// The load-bearing test. The three tone dials were measured to compose by *adding* their
    /// deviations from the identity; serial composition lost by 3x on two of the three pairs. Both
    /// models agree wherever one dial is flat, so the assertion has to be made at an input where
    /// both are working — the upper midtones, which is also where additive is at its worst.
    func testTheThreeToneDialsAddTheirDeviations() throws {
        let highlight = try XCTUnwrap(CameraLookToneComposite.curve(for: look(tone: [("HL", 7)])))
        let midtone = try XCTUnwrap(CameraLookToneComposite.curve(for: look(tone: [("Mid", -7)])))
        let both = try XCTUnwrap(
            CameraLookToneComposite.curve(for: look(tone: [("HL", 7), ("Mid", -7)])))

        for input in [144, 160, 176] {
            let sum = Double(input)
                + (highlight[input] - Double(input))
                + (midtone[input] - Double(input))
            XCTAssertEqual(both[input], sum, accuracy: 0.01)
        }
    }

    /// Contrast was measured as a separate serial stage applied *first*, so its output is what the
    /// tone dials then read. Serial and additive differ here, which is what makes this assertable.
    func testContrastIsAppliedBeforeTheToneDials() throws {
        let composite = try XCTUnwrap(
            CameraLookToneComposite.curve(for: look(tone: [("Mid", 7)], contrast: 2)))

        let contrast = try XCTUnwrap(CameraLookToneComposite.deviation(code: "Contrast", value: 2))
        let midtone = try XCTUnwrap(CameraLookToneComposite.deviation(code: "Mid", value: 7))
        let afterContrast = 128 + CameraLookToneComposite.interpolate(contrast, at: 128)
        let expected = afterContrast + CameraLookToneComposite.interpolate(midtone, at: afterContrast)

        XCTAssertEqual(composite[128], expected, accuracy: 0.01)
    }

    /// Gradation overrides the contrast dial entirely — measured on High Key, Low Key and Auto —
    /// *and the maker note still records the value the camera ignored*, so a populated `contrast`
    /// is not evidence it was applied. Two looks differing only in contrast must draw identically.
    func testGradationSuppressesContrastEntirely() throws {
        let plain = CameraLookToneComposite.curve(for: look(gradation: "high key"))
        let withContrast = CameraLookToneComposite.curve(for: look(contrast: 2, gradation: "high key"))

        XCTAssertEqual(try XCTUnwrap(plain), try XCTUnwrap(withContrast))
        XCTAssertTrue(CameraLookToneComposite.contrastIsSuppressed(look(gradation: "low key")))
        XCTAssertTrue(CameraLookToneComposite.contrastIsSuppressed(look(gradationIsAuto: true)))
        XCTAssertFalse(CameraLookToneComposite.contrastIsSuppressed(look(contrast: 2)))
    }

    // MARK: - What must not be drawn

    /// Gradation Auto is a per-frame decision the camera leaves no trace of, so there is no curve
    /// to draw even when the tone dials were moved — drawing them alone would show a curve the
    /// frame was not rendered with.
    func testGradationAutoHasNoCurve() {
        XCTAssertNil(CameraLookToneComposite.curve(for: look(gradationIsAuto: true)))
        XCTAssertNil(
            CameraLookToneComposite.curve(for: look(tone: [("HL", 7)], gradationIsAuto: true)))
    }

    /// A look that dialled nothing, and one that dialled everything to zero, are the same thing.
    func testNothingDialledHasNoCurve() {
        XCTAssertNil(CameraLookToneComposite.curve(for: look()))
        XCTAssertNil(CameraLookToneComposite.curve(for: look(tone: [("HL", 0)], contrast: 0)))
    }

    // MARK: - Interpolation

    /// Only the odd steps were shot. An even one has to land between its neighbours rather than
    /// falling back to zero or to the nearest measured curve.
    func testAnUnmeasuredDialStepInterpolates() throws {
        let low = try XCTUnwrap(CameraLookToneComposite.deviation(code: "Mid", value: 1))
        let high = try XCTUnwrap(CameraLookToneComposite.deviation(code: "Mid", value: 3))
        let between = try XCTUnwrap(CameraLookToneComposite.deviation(code: "Mid", value: 2))

        for knot in low.indices {
            XCTAssertEqual(between[knot], (low[knot] + high[knot]) / 2, accuracy: 0.001)
        }
    }

    /// The +-1 steps interpolate against an implicit all-zero curve at 0, which is the only
    /// "measured" curve nobody shot. Without it, +-1 would have no lower bracket at all.
    func testTheSmallestStepsStillResolve() {
        XCTAssertNotNil(CameraLookToneComposite.deviation(code: "HL", value: 1))
        XCTAssertNotNil(CameraLookToneComposite.deviation(code: "SH", value: -1))
    }

    // MARK: - Shape

    /// Every measured curve is monotonic and pinned at both corners, and stacking three dials the
    /// same way must not break either — a composite that crossed itself would be a rendering the
    /// camera cannot produce.
    func testAStackedCompositeStaysMonotonicAndPinned() throws {
        let curve = try XCTUnwrap(
            CameraLookToneComposite.curve(
                for: look(tone: [("HL", 7), ("Mid", 5), ("SH", -7)], contrast: 2)))

        XCTAssertEqual(curve[0], 0, accuracy: 0.01)
        XCTAssertEqual(curve[255], 255, accuracy: 0.01)
        for input in 1...255 {
            XCTAssertGreaterThanOrEqual(
                curve[input], curve[input - 1] - 0.001, "composite dips at input \(input)")
        }
    }

    /// The knots are joined by straight lines, so the curve is only as smooth as its sampling — and
    /// a value error that passes can still leave a corner you can see, because the eye reads the
    /// change in slope rather than the displacement. Sixteen-level spacing alone cost 0.87 of a level
    /// of slope in Contrast +2 at knot 224, where the curve turns hardest into white, while sitting
    /// well inside the 2-level value budget the spacing was chosen on. Bound is 0.6, which every dial
    /// clears; the largest genuine break in the measured data is Shadow +7 at input 32 (0.57).
    func testNoCurveTurnsSharplyEnoughToLookLikeACorner() throws {
        for value in [-2, -1, 1, 2] {
            let curve = try XCTUnwrap(CameraLookToneComposite.curve(for: look(contrast: value)))
            let slopes = (1...255).map { curve[$0] - curve[$0 - 1] }
            for input in 1..<slopes.count {
                XCTAssertLessThan(
                    abs(slopes[input] - slopes[input - 1]), 0.6,
                    "Contrast \(value) breaks slope at input \(input + 1)")
            }
        }
    }

    // MARK: - The table itself

    /// The table is generated from the CSV, so this guards the join rather than the numbers: the
    /// dial codes must be the ones `CameraLookParsing` emits, and every step the camera offers
    /// must resolve to a curve.
    func testEveryDialStepTheCameraOffersResolves() {
        for code in ["HL", "Mid", "SH"] {
            for value in -7...7 {
                XCTAssertNotNil(
                    CameraLookToneComposite.deviation(code: code, value: value),
                    "no curve for \(code) \(value)")
            }
        }
        for value in -2...2 {
            XCTAssertNotNil(CameraLookToneComposite.deviation(code: "Contrast", value: value))
        }
    }

    /// Parsing a real tone tag has to produce codes this table knows, or a dialled curve would
    /// silently draw as nothing. Same coupling `CameraLookGeometryTests` guards for the spokes.
    func testParsedToneCodesResolveAgainstTheTable() throws {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Profile 1; 2",
            "Olympus:ToneLevel":
                "Highlights; 7; -7; 7; Shadows; -3; -7; 7; Midtones; 2; -7; 7; 0; 0; 0; 0",
        ]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))
        XCTAssertEqual(look.toneLevels.count, 3)
        for slider in look.toneLevels {
            XCTAssertNotNil(
                CameraLookToneComposite.deviation(code: slider.code, value: slider.value),
                "parsed code \(slider.code) has no curve")
        }
    }
}
