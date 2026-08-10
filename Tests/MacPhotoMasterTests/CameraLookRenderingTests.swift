import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Which hero graphic a look calls for. Driven through `CameraLookParsing` from PrintConv-shaped
/// metadata rather than from hand-built `CameraLook` values, so a test can't pass on a combination
/// the parser would never actually produce.
final class CameraLookRenderingTests: XCTestCase {
    /// All-zero versions of the tags the parser reads unconditionally, so each test below only has
    /// to state the tags it is actually about.
    private static let neutralTags: [String: Any] = [
        "Olympus:ColorProfileSettings":
            "Min -5; Max 5; Yellow 0; Orange 0; Orange-red 0; Red 0; Magenta 0; Violet 0;"
            + " Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
        "Olympus:ColorCreatorEffect": "Color 0; 0; 29; Strength 0; -4; 3",
        "Olympus:MonochromeProfileSettings": "No Filter; 0; 8; Strength 0; 0; 3",
        "Olympus:MonochromeColor": "Normal",
        "Olympus:PictureModeBWFilter": "n/a",
        "Olympus:PictureModeTone": "n/a",
    ]

    private func rendering(_ tags: [String: Any]) -> CameraLookRendering? {
        let metadata = Self.neutralTags.merging(tags) { _, new in new }
        guard let look = CameraLookParsing.parse(from: metadata) else { return nil }
        return CameraLookRendering.rendering(for: look)
    }

    // MARK: - Colour Profile spokes

    func testDialledSpokesGiveTheProfileWheel() {
        let result = rendering([
            "Olympus:PictureMode": "Color Profile 2; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 3; Orange 0; Orange-red 0; Red -2; Magenta 0; Violet 0;"
                + " Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
        ])

        guard case .profileSpokes(let sliders) = result else {
            return XCTFail("expected the profile wheel, got \(String(describing: result))")
        }
        XCTAssertEqual(sliders.map(\.code), ["Y", "R"])
        XCTAssertEqual(sliders.map(\.value), [3, -2])
    }

    // MARK: - Colour Creator

    func testColorCreatorGivesItsRing() {
        let result = rendering([
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 11; 0; 29; Strength 2; -4; 3",
        ])

        guard case .colorCreator(let creator) = result else {
            return XCTFail("expected the Colour Creator ring, got \(String(describing: result))")
        }
        XCTAssertEqual(creator.position, 11)
        XCTAssertEqual(creator.strength, 2)
        XCTAssertFalse(creator.isMonochrome)
    }

    /// At Vivid -4 the output is exact monochrome, but the cast is applied *before* the
    /// desaturation, so the ring position still decides which hues render light or dark. Collapsing
    /// this into `.monochrome` would throw that away — the case that documents the decision.
    func testColorCreatorAtMonochromeStrengthKeepsItsRing() {
        let result = rendering([
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 26; 0; 29; Strength -4; -4; 3",
        ])

        guard case .colorCreator(let creator) = result else {
            return XCTFail("expected the ring to survive, got \(String(describing: result))")
        }
        XCTAssertTrue(creator.isMonochrome)
        XCTAssertEqual(creator.position, 26, "the position still decides the tonal mapping")
    }

    // MARK: - Partial Color

    func testPartialColorGivesItsBand() {
        let result = rendering([
            "Olympus:ArtFilterEffect":
                "Partial Color; 0; 0; Partial Color 3; No Effect; 0; No Color Filter; 0;"
                + " 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ])

        guard case .partialColor(let stop, let name, let band) = result else {
            return XCTFail("expected the Partial Color band, got \(String(describing: result))")
        }
        XCTAssertEqual(stop, 3)
        XCTAssertEqual(name, "red")
        XCTAssertEqual(band.center, CameraLookGeometry.partialColorCenter(stop: 3))
        XCTAssertEqual(band.floor, 0, "type I removes the rest of the wheel entirely")
    }

    /// The variant is only recoverable from the filter's name, and II is the one that leaves chroma
    /// standing everywhere else — so getting the type wrong silently draws the wrong picture.
    func testPartialColorTwoCarriesItsFloor() {
        let result = rendering([
            "Olympus:ArtFilterEffect":
                "Partial Color II; 0; 0; Partial Color 9; No Effect; 0; No Color Filter; 0;"
                + " 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ])

        guard case .partialColor(_, _, let band) = result else {
            return XCTFail("expected the Partial Color band, got \(String(describing: result))")
        }
        XCTAssertEqual(band.floor, 0.17, accuracy: 0.001)
    }

    /// The stale-reading case the priority order exists for: a Grainy Film frame carries
    /// `"Partial Color 0"` in the same tag, and the parser already gates on the filter name so no
    /// band is produced. This proves the gate holds all the way to the graphic.
    func testGrainyFilmDoesNotDrawAPartialColorBand() {
        let result = rendering([
            "Olympus:ArtFilterEffect":
                "Grainy Film; 0; 0; Partial Color 0; No Effect; 0; No Color Filter; 0;"
                + " 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
            "Olympus:FilmGrainEffect": "Low",
        ])

        if case .partialColor = result {
            XCTFail("a stale Partial Color reading must not outvote the live filter")
        }
    }

    /// Partial Color leads the priority order because `hueSliders` carries no staleness gate of its
    /// own and would otherwise outvote a live band.
    func testPartialColorBeatsStaleProfileSpokes() {
        let result = rendering([
            "Olympus:ArtFilterEffect":
                "Partial Color; 0; 0; Partial Color 5; No Effect; 0; No Color Filter; 0;"
                + " 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 4; Orange 0; Orange-red 0; Red 0; Magenta 0; Violet 0;"
                + " Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
        ])

        guard case .partialColor(let stop, _, _) = result else {
            return XCTFail("expected the band to win, got \(String(describing: result))")
        }
        XCTAssertEqual(stop, 5)
    }

    // MARK: - Monochrome, merged across its three routes

    /// Route 1: the monochrome profiles, the only route that records a separate strength.
    func testMonochromeProfileRouteMerges() {
        let result = rendering([
            "Olympus:PictureMode": "Monochrome Profile 3; 2",
            "Olympus:MonochromeProfileSettings": "Red Filter; 0; 8; Strength 3; 0; 3",
            "Olympus:MonochromeColor": "Sepia",
        ])

        guard case .monochrome(let mono) = result else {
            return XCTFail("expected monochrome, got \(String(describing: result))")
        }
        XCTAssertEqual(mono.filter, "red")
        XCTAssertEqual(mono.filterStrength, 3)
        XCTAssertEqual(mono.tint, "sepia")
    }

    /// Route 2: the Monotone picture mode, whose two tags use a *different numbering* for the same
    /// option lists. Merging them for display is safe precisely because the parser resolved each to
    /// a name first.
    func testMonotoneRouteMergesToTheSameShape() {
        let result = rendering([
            "Olympus:PictureMode": "Monotone; 2",
            "Olympus:PictureModeBWFilter": "Orange",
            "Olympus:PictureModeTone": "Blue",
        ])

        guard case .monochrome(let mono) = result else {
            return XCTFail("expected monochrome, got \(String(describing: result))")
        }
        XCTAssertEqual(mono.filter, "orange")
        XCTAssertEqual(mono.tint, "blue")
        XCTAssertNil(mono.filterStrength, "Monotone records no strength")
    }

    /// Route 3: the art filters' stacked records. `0x8070` is the tint record, which exiftool
    /// renders through the colour-filter table anyway — so this also proves the merge reads the
    /// parser's resolved value rather than the misleading PrintConv text.
    func testArtFilterRouteMergesToTheSameShape() {
        let result = rendering([
            "Olympus:ArtFilterEffect":
                "Dramatic Tone; 0; 0; 0; B&W; 0; Yellow Color Filter; 0;"
                + " 32880; 0; 2; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ])

        guard case .monochrome(let mono) = result else {
            return XCTFail("expected monochrome, got \(String(describing: result))")
        }
        XCTAssertEqual(mono.filter, "yellow")
        // The `0x8070` record's value 2 is a blue tint. exiftool prints field 6 through its
        // colour-filter table whatever the record means, so the *text* here says "Yellow Color
        // Filter" for the separate `0x8060` record — the tint is only correct because the parser
        // dispatched on the code. That is exactly what this asserts.
        XCTAssertEqual(mono.tint, "blue")
        XCTAssertNil(mono.filterStrength, "art filters record no strength")
    }

    /// A stacked option that isn't a filter or a tint is finish, not colour rendering, and must not
    /// on its own claim the hero graphic away from the spokes.
    func testStackedEffectAloneIsNotMonochrome() {
        let result = rendering([
            "Olympus:ArtFilterEffect":
                "Grainy Film; 0; 0; 0; Star Light; 0; No Color Filter; 0;"
                + " 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 2; Orange 0; Orange-red 0; Red 0; Magenta 0; Violet 0;"
                + " Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
        ])

        guard case .profileSpokes = result else {
            return XCTFail("a Star Light record is finish, got \(String(describing: result))")
        }
    }

    // MARK: - Nothing to draw

    /// A mode with readings that are all outside group 2 still has no hero graphic — the tone curve
    /// and sliders are their own groups.
    func testToneOnlyLookHasNoColourGraphic() {
        let result = rendering([
            "Olympus:PictureMode": "Vivid; 2",
            "Olympus:PictureModeContrast": "2 (min -2, max 2)",
        ])

        XCTAssertEqual(result, CameraLookRendering.none)
    }
}
