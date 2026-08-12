import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Guards the measured ring geometry (see `scripts/README.md`) against silent drift, and — the part
/// that actually matters — against `CameraLookParsing` and `CameraLookGeometry` disagreeing about
/// the spoke codes that join them.
final class CameraLookGeometryTests: XCTestCase {
    // MARK: - Colour Profile spokes

    /// The load-bearing test of the file. `hueSpokeCenters` is keyed by `CameraLookParsing`'s
    /// private `hueCodes`, so a rename there would leave the wheel silently unable to place a
    /// spoke. Parsing a real all-spokes-dialled tag and demanding every emitted code resolve is
    /// what couples the two without exposing the parser's internals.
    func testEveryParsedSpokeCodeHasAMeasuredCenter() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Profile 1; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 1; Orange 2; Orange-red 3; Red 4; Magenta 5; Violet -1;"
                + " Blue -2; Blue-cyan -3; Cyan -4; Green-cyan -5; Green 1; Yellow-green 2",
        ]

        let look = CameraLookParsing.parse(from: metadata)
        XCTAssertEqual(look?.hueSliders.count, 12, "all twelve spokes were dialled off zero")

        for slider in look?.hueSliders ?? [] {
            XCTAssertNotNil(
                CameraLookGeometry.hueSpokeCenters[slider.code],
                "no measured centre for spoke code \(slider.code)")
        }
    }

    /// The parser emits spokes in the camera's order, and `hueSpokeOrder` claims to be that order.
    func testSpokeOrderMatchesTheParsersEmissionOrder() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Profile 1; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 1; Orange 1; Orange-red 1; Red 1; Magenta 1; Violet 1;"
                + " Blue 1; Blue-cyan 1; Cyan 1; Green-cyan 1; Green 1; Yellow-green 1",
        ]

        let codes = CameraLookParsing.parse(from: metadata)?.hueSliders.map(\.code)
        XCTAssertEqual(codes, CameraLookGeometry.hueSpokeOrder)
    }

    func testSpokeOrderAndCentersCoverTheSameTwelveCodes() {
        XCTAssertEqual(
            Set(CameraLookGeometry.hueSpokeOrder),
            Set(CameraLookGeometry.hueSpokeCenters.keys))
        XCTAssertEqual(CameraLookGeometry.hueSpokeOrder.count, 12)
    }

    /// The measurement's headline finding: the twelve are perceptually spaced, not geometrically.
    /// If someone "tidies" the table to twelve-times-30 this fails rather than quietly redrawing
    /// every marker in the wrong place.
    func testSpokesAreNotEvenlySpaced() {
        let gaps = spokeGaps()
        let minimum = gaps.min() ?? 0
        let maximum = gaps.max() ?? 0

        XCTAssertEqual(minimum, 11.7, accuracy: 0.05, "tightest gap, Red to Magenta")
        XCTAssertEqual(maximum, 44.1, accuracy: 0.05, "widest gap, Violet to Blue")
        XCTAssertGreaterThan(maximum - minimum, 30, "spacing is genuinely uneven")
    }

    /// The twelve are strictly ordered and run anticlockwise in increasing index, so consecutive
    /// gaps taken in one direction must close to exactly 360 with no doubling back.
    func testSpokeGapsCloseTheCircle() {
        let gaps = spokeGaps()
        XCTAssertEqual(gaps.count, 12)
        XCTAssertEqual(gaps.reduce(0, +), 360, accuracy: 0.01)
        for gap in gaps {
            XCTAssertGreaterThan(gap, 0, "a non-positive gap means the order doubles back")
        }
    }

    // MARK: - Spoke readings and interpolation

    /// A shape needs a value at every vertex, so an undialled spoke has to come back as zero rather
    /// than be dropped — the parser emits only what moved.
    func testSpokeReadingsFillInTheUndialledSpokes() {
        let readings = CameraLookGeometry.spokeReadings([
            CameraLook.Slider(code: "R", value: -4), CameraLook.Slider(code: "G", value: 5),
        ])

        XCTAssertEqual(readings.count, 12)
        XCTAssertEqual(readings.first { $0.code == "R" }?.value, -4)
        XCTAssertEqual(readings.first { $0.code == "G" }?.value, 5)
        XCTAssertEqual(readings.first { $0.code == "B" }?.value, 0, "undialled, not missing")
        XCTAssertEqual(
            Set(readings.map(\.code)), Set(CameraLookGeometry.hueSpokeOrder),
            "every spoke is a vertex")
    }

    func testSpokeReadingsAreSortedByHueSoTheCircleCanBeWalked() {
        let readings = CameraLookGeometry.spokeReadings([])
        XCTAssertEqual(readings.map(\.hue), readings.map(\.hue).sorted())
    }

    func testInterpolationReturnsTheDialledValueAtASpokeCenter() {
        let readings = CameraLookGeometry.spokeReadings([CameraLook.Slider(code: "B", value: 3)])
        let blue = CameraLookGeometry.hueSpokeCenters["B"]!

        XCTAssertEqual(
            CameraLookGeometry.interpolatedSpokeValue(at: blue, readings: readings), 3,
            accuracy: 0.001)
    }

    /// Halfway between two spokes is the mean of their values, which is what makes the disc blend
    /// rather than step. Cyan (195.5) and Blue-cyan (210.2) are adjacent.
    func testInterpolationIsLinearBetweenNeighbours() {
        let readings = CameraLookGeometry.spokeReadings([
            CameraLook.Slider(code: "C", value: 0), CameraLook.Slider(code: "Bc", value: 4),
        ])

        XCTAssertEqual(
            CameraLookGeometry.interpolatedSpokeValue(at: 202.85, readings: readings), 2,
            accuracy: 0.01)
    }

    /// The gap holding 0/360 is between Orange-red (349.8) and Orange (24.3), so an angle inside it
    /// must interpolate across the wrap rather than fall off either end.
    func testInterpolationWrapsThroughZero() {
        let readings = CameraLookGeometry.spokeReadings([
            CameraLook.Slider(code: "Or", value: -5), CameraLook.Slider(code: "O", value: 5),
        ])
        let span = 24.3 + 360 - 349.8

        XCTAssertEqual(
            CameraLookGeometry.interpolatedSpokeValue(at: 349.8 + span / 2, readings: readings), 0,
            accuracy: 0.01, "the midpoint of the wrapped gap")
        XCTAssertEqual(
            CameraLookGeometry.interpolatedSpokeValue(at: 0, readings: readings),
            -5 + 10 * (10.2 / span), accuracy: 0.01, "hue 0 itself sits inside the gap")
    }

    /// Uneven spacing has to survive interpolation: a fixed step away from a spoke covers more of
    /// the tight Red-to-Magenta gap (11.7) than of the wide Violet-to-Blue one (44.1).
    func testInterpolationInheritsTheUnevenSpacing() {
        let readings = CameraLookGeometry.spokeReadings([
            CameraLook.Slider(code: "R", value: 0), CameraLook.Slider(code: "M", value: 5),
            CameraLook.Slider(code: "V", value: 0), CameraLook.Slider(code: "B", value: 5),
        ])

        let tight = CameraLookGeometry.interpolatedSpokeValue(
            at: CameraLookGeometry.hueSpokeCenters["R"]! - 5, readings: readings)
        let wide = CameraLookGeometry.interpolatedSpokeValue(
            at: CameraLookGeometry.hueSpokeCenters["V"]! - 5, readings: readings)

        XCTAssertGreaterThan(tight, wide, "the same 5 degrees travels further in a tighter gap")
    }

    func testInterpolationOfAnUntouchedProfileIsFlatZero() {
        let readings = CameraLookGeometry.spokeReadings([])
        for hue in stride(from: 0.0, to: 360.0, by: 7.0) {
            XCTAssertEqual(
                CameraLookGeometry.interpolatedSpokeValue(at: hue, readings: readings), 0,
                accuracy: 0.001)
        }
    }

    /// Anticlockwise means hue *decreases* with the index, so each step is the drop to the next.
    private func spokeGaps() -> [Double] {
        let centers = CameraLookGeometry.hueSpokeOrder.compactMap {
            CameraLookGeometry.hueSpokeCenters[$0]
        }
        return centers.indices.map { index in
            let next = centers[(index + 1) % centers.count]
            return CameraLookGeometry.normalized(centers[index] - next)
        }
    }

    // MARK: - Partial Color

    func testPartialColorStopZeroIsYellowAndStepsDown() {
        XCTAssertEqual(CameraLookGeometry.partialColorCenter(stop: 0), 64.1, accuracy: 0.01)
        XCTAssertEqual(CameraLookGeometry.partialColorCenter(stop: 1), 44.1, accuracy: 0.01)
        XCTAssertEqual(CameraLookGeometry.partialColorCenter(stop: 9), 244.1, accuracy: 0.01)
    }

    /// Eighteen stops at 20 degrees is a full circle, so stop 18 would land back on stop 0. The
    /// wrap is what keeps the high stops on the wheel instead of running off past 360.
    func testPartialColorRingCloses() {
        XCTAssertEqual(
            CameraLookGeometry.partialColorCenter(stop: CameraLookGeometry.partialColorStopCount),
            CameraLookGeometry.partialColorCenter(stop: 0),
            accuracy: 0.01)

        for stop in 0..<CameraLookGeometry.partialColorStopCount {
            let center = CameraLookGeometry.partialColorCenter(stop: stop)
            XCTAssertGreaterThanOrEqual(center, 0)
            XCTAssertLessThan(center, 360)
        }
    }

    /// The measured stop-3 centre is red (360.0) and stop 9 blue (248.0) in the type table; the
    /// formula has to reproduce those independently of it.
    func testFormulaAgreesWithTheIndependentlyMeasuredStops() {
        XCTAssertEqual(CameraLookGeometry.partialColorCenter(stop: 3), 4.1, accuracy: 5.0)
        XCTAssertEqual(CameraLookGeometry.partialColorCenter(stop: 9), 244.1, accuracy: 5.0)
        XCTAssertEqual(CameraLookGeometry.partialColorCenter(stop: 15), 124.1, accuracy: 5.0)
    }

    func testPartialColorTypeReadsTheModeName() {
        XCTAssertEqual(CameraLookGeometry.PartialColorType(mode: "Partial Color"), .one)
        XCTAssertEqual(CameraLookGeometry.PartialColorType(mode: "Partial Color II"), .two)
        XCTAssertEqual(CameraLookGeometry.PartialColorType(mode: "Partial Color III"), .three)
        XCTAssertNil(CameraLookGeometry.PartialColorType(mode: "Grainy Film"))
    }

    /// `"Partial Color II"` is a prefix of `"Partial Color III"`, so a `hasPrefix` implementation
    /// would call III a II. This is the test that catches that.
    func testPartialColorTypeThreeIsNotMistakenForTwo() {
        XCTAssertNotEqual(CameraLookGeometry.PartialColorType(mode: "Partial Color III"), .two)
    }

    /// The three differ at the shoulders and in the floor, not in band width — see
    /// `partialColorBand(stop:type:)` for why II's raw measured width is not used.
    func testTheThreeTypesShareABandAndDifferAtTheEdges() {
        let one = CameraLookGeometry.partialColorBand(stop: 3, type: .one)
        let two = CameraLookGeometry.partialColorBand(stop: 3, type: .two)
        let three = CameraLookGeometry.partialColorBand(stop: 3, type: .three)

        XCTAssertEqual(one.width, two.width)
        XCTAssertEqual(one.width, three.width)

        XCTAssertEqual(one.floor, 0, "I removes the rest of the wheel entirely")
        XCTAssertEqual(three.floor, 0, "so does III")
        XCTAssertEqual(two.floor, 0.17, accuracy: 0.001, "II retains 16-20% chroma elsewhere")

        XCTAssertLessThan(three.edge, one.edge, "III has the harder shoulder")
    }

    func testPartialColorBandCenterFollowsTheStop() {
        for type in [CameraLookGeometry.PartialColorType.one, .two, .three] {
            XCTAssertEqual(
                CameraLookGeometry.partialColorBand(stop: 7, type: type).center,
                CameraLookGeometry.partialColorCenter(stop: 7))
        }
    }

    // MARK: - Band falloff

    /// FWHM means exactly this: half the response at the half-width. A band drawn any other way is
    /// not the band that was measured.
    func testChromaIsHalfAtTheHalfWidth() {
        let band = CameraLookGeometry.partialColorBand(stop: 0, type: .one)
        let atHalf = CameraLookGeometry.retainedChroma(
            band, at: band.center + band.width / 2)

        XCTAssertEqual(atHalf, 0.5, accuracy: 0.001)
    }

    func testChromaPeaksAtTheBandCenter() {
        let band = CameraLookGeometry.partialColorBand(stop: 6, type: .one)
        XCTAssertEqual(CameraLookGeometry.retainedChroma(band, at: band.center), 1.0, accuracy: 0.001)
    }

    /// The 90%-to-10% fall has to span `edge` degrees, not some multiple — that number is the whole
    /// of what separates type III's hard shoulder from type I's soft one.
    func testNinetyToTenFallSpansTheMeasuredEdge() {
        for type in [CameraLookGeometry.PartialColorType.one, .three] {
            let band = CameraLookGeometry.partialColorBand(stop: 0, type: type)
            let ninety = band.center + band.width / 2 - band.edge / 2
            let ten = band.center + band.width / 2 + band.edge / 2

            XCTAssertEqual(
                CameraLookGeometry.retainedChroma(band, at: ninety), 0.9, accuracy: 0.001,
                "type \(type)")
            XCTAssertEqual(
                CameraLookGeometry.retainedChroma(band, at: ten), 0.1, accuracy: 0.001,
                "type \(type)")
        }
    }

    /// Types I and III strip the opposite side of the wheel completely; II leaves its floor there.
    /// This is the difference the visualiser exists to show.
    func testFloorIsWhatSeparatesTypeTwo() {
        let opposite = 180.0

        for type in [CameraLookGeometry.PartialColorType.one, .three] {
            let band = CameraLookGeometry.partialColorBand(stop: 0, type: type)
            XCTAssertEqual(
                CameraLookGeometry.retainedChroma(band, at: band.center + opposite), 0,
                accuracy: 0.001, "type \(type) removes the rest of the wheel")
        }

        let two = CameraLookGeometry.partialColorBand(stop: 0, type: .two)
        XCTAssertEqual(
            CameraLookGeometry.retainedChroma(two, at: two.center + opposite), 0.17,
            accuracy: 0.001, "type II retains its floor")
    }

    /// Type II's floor lifts the whole curve, so its half-height sits above types I and III's — the
    /// artefact that made II's raw measured FWHM read wide. Asserted so the model keeps reproducing
    /// the measurement rather than the conclusion drawn from it.
    func testTypeTwoNeverFallsBelowItsFloor() {
        let band = CameraLookGeometry.partialColorBand(stop: 4, type: .two)
        for hue in stride(from: 0.0, to: 360.0, by: 1.0) {
            XCTAssertGreaterThanOrEqual(
                CameraLookGeometry.retainedChroma(band, at: hue), band.floor - 0.0001,
                "hue \(hue) dipped below the floor")
        }
    }

    /// Chroma is a fraction; nothing may leave 0...1 whatever the hue or type.
    func testChromaStaysInRange() {
        for type in [CameraLookGeometry.PartialColorType.one, .two, .three] {
            for stop in 0..<CameraLookGeometry.partialColorStopCount {
                let band = CameraLookGeometry.partialColorBand(stop: stop, type: type)
                for hue in stride(from: 0.0, to: 360.0, by: 3.0) {
                    let chroma = CameraLookGeometry.retainedChroma(band, at: hue)
                    XCTAssertGreaterThanOrEqual(chroma, 0)
                    XCTAssertLessThanOrEqual(chroma, 1)
                }
            }
        }
    }

    /// The falloff must wrap the circle: a band centred near 0 has to treat 359 as one degree away,
    /// not 359. Stop 3 sits at 4.1 degrees, so this is a real case and not a contrived one.
    func testFalloffWrapsAroundZero() {
        let band = CameraLookGeometry.partialColorBand(stop: 3, type: .one)
        XCTAssertEqual(band.center, 4.1, accuracy: 0.01)

        let justBelowZero = CameraLookGeometry.retainedChroma(band, at: 359)
        let sameDistanceAbove = CameraLookGeometry.retainedChroma(band, at: 9.2)

        XCTAssertEqual(justBelowZero, sameDistanceAbove, accuracy: 0.02)
        XCTAssertGreaterThan(justBelowZero, 0.9, "5 degrees off centre is still inside the core")
    }

    func testAngularDistanceTakesTheShortWayRound() {
        XCTAssertEqual(CameraLookGeometry.angularDistance(10, 350), 20, accuracy: 0.001)
        XCTAssertEqual(CameraLookGeometry.angularDistance(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(CameraLookGeometry.angularDistance(0, 180), 180, accuracy: 0.001)
        XCTAssertEqual(CameraLookGeometry.angularDistance(90, 90), 0, accuracy: 0.001)
    }

    // MARK: - Colour Creator

    /// Position 0 imposes no hue — it is a pure saturation control, and drawing a hue marker for it
    /// would invent a cast the camera does not apply.
    func testColorCreatorPositionZeroIsNeutral() {
        XCTAssertNil(CameraLookGeometry.colorCreatorHue(position: 0))
    }

    func testColorCreatorCoversAllThirtyPositions() {
        for position in 1..<CameraLookGeometry.colorCreatorPositionCount {
            XCTAssertNotNil(
                CameraLookGeometry.colorCreatorHue(position: position),
                "position \(position) has no measured hue")
        }
        XCTAssertNil(CameraLookGeometry.colorCreatorHue(position: 30), "out of range")
        XCTAssertNil(CameraLookGeometry.colorCreatorHue(position: -1), "out of range")
    }

    /// The petal's depth is the Vivid axis rescaled, so the two ends have to land exactly on the two
    /// ends of the graphic: the strongest boost reaches the middle, and the monochrome end keeps only
    /// the legibility nub that says which position it was. In between it has to rise with strength —
    /// a depth that ran the other way would read as a stronger cast for a weaker setting.
    func testColorCreatorReachSpansTheWheelAcrossTheVividRange() {
        let range = CameraLookGeometry.colorCreatorStrengthRange
        XCTAssertEqual(CameraLookGeometry.colorCreatorReach(strength: range.upperBound), 1.0)
        XCTAssertEqual(CameraLookGeometry.colorCreatorReach(strength: range.lowerBound), 0.15)

        for strength in (range.lowerBound + 1)...range.upperBound {
            XCTAssertGreaterThan(
                CameraLookGeometry.colorCreatorReach(strength: strength),
                CameraLookGeometry.colorCreatorReach(strength: strength - 1),
                "Vivid \(strength) reaches no further than \(strength - 1)")
        }
    }

    /// Nothing outside the range reaches here from the parser, but the reach is a radius — a value
    /// past either end would draw a petal outside the wheel or inside out.
    func testColorCreatorReachStaysOnTheWheel() {
        for strength in -20...20 {
            let reach = CameraLookGeometry.colorCreatorReach(strength: strength)
            XCTAssertGreaterThanOrEqual(reach, 0.15)
            XCTAssertLessThanOrEqual(reach, 1.0)
        }
    }

    /// Position 26 measures green, which the camera's own header independently confirms by drawing
    /// a green swatch for it. The one anchor in the table that has outside corroboration.
    func testColorCreatorPositionTwentySixIsGreen() {
        let hue = CameraLookGeometry.colorCreatorHue(position: 26)
        XCTAssertEqual(hue ?? 0, 113, accuracy: 1)
    }

    /// Hue decreases with the index, the same direction as Partial Color. Positions 3-5 are the
    /// known non-monotonic patch (13, 21, 14 — framing noise across a wall with a mild gradient),
    /// and 17-18 repeat exactly, so the run is checked as non-increasing with that one patch
    /// excused rather than as strictly decreasing.
    func testColorCreatorHueDecreasesWithIndexApartFromTheKnownWobble() {
        let hues = (1..<CameraLookGeometry.colorCreatorPositionCount).compactMap {
            CameraLookGeometry.colorCreatorHue(position: $0)
        }
        // The table crosses 360 between positions 5 and 6 (14 -> 358); unwrap so the comparison is
        // about the sweep rather than about where zero happens to fall.
        var unwrapped: [Double] = []
        var turns = 0.0
        for (index, hue) in hues.enumerated() {
            if index > 0, hue > hues[index - 1] + 180 { turns -= 360 }
            unwrapped.append(hue + turns)
        }

        for index in 1..<unwrapped.count where !(3...5).contains(index + 1) {
            XCTAssertLessThanOrEqual(
                unwrapped[index], unwrapped[index - 1] + 0.001,
                "position \(index + 1) rises against position \(index)")
        }

        XCTAssertLessThan(unwrapped.last ?? 0, unwrapped.first ?? 0, "the sweep runs downward")
    }

    // MARK: - Shared

    func testNormalizedFoldsIntoOneTurn() {
        XCTAssertEqual(CameraLookGeometry.normalized(0), 0, accuracy: 0.001)
        XCTAssertEqual(CameraLookGeometry.normalized(360), 0, accuracy: 0.001)
        XCTAssertEqual(CameraLookGeometry.normalized(-20), 340, accuracy: 0.001)
        XCTAssertEqual(CameraLookGeometry.normalized(-380), 340, accuracy: 0.001)
        XCTAssertEqual(CameraLookGeometry.normalized(725), 5, accuracy: 0.001)
    }
}
