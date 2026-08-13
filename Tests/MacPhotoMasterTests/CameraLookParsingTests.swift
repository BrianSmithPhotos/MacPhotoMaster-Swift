import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Fixtures are the real strings `exiftool -j -G1 -a -s` returned for OM-3 files — the same flags
/// `ExifToolClient.readArguments` uses. That matters: without `-n` these maker-note arrays are
/// PrintConv text with the camera's slider min/max padded in, not plain numbers, so a fixture
/// written as numbers would pass while the app read nothing.
final class CameraLookParsingTests: XCTestCase {
    /// H1071739.JPG — Monochrome Profile 3, red filter strength 3, grain Low, shading +5.
    private let monoProfile3: [String: Any] = [
        "Olympus:PictureMode": "Monochrome Profile 3; 2",
        "Olympus:MonochromeProfileSettings": "Red Filter; 0; 8; Strength 3; 0; 3",
        "Olympus:FilmGrainEffect": "Low",
        "Olympus:MonochromeVignetting": 5,
        "Olympus:MonochromeColor": "Normal",
        "Olympus:ColorProfileSettings":
            "Min -5; Max 5; Yellow 0; Orange 0; Orange-red 0; Red 0; Magenta 0; Violet 0; Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
        "Olympus:ColorCreatorEffect": "Color 0; 0; 29; Strength 0; -4; 3",
        "Olympus:ToneLevel":
            "Highlights; 0; -7; 7; Shadows; 0; -7; 7; Midtones; 0; -7; 7; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        "Olympus:ArtFilterEffect":
            "Off; 0; 0; Partial Color 0; No Effect; 0; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
    ]

    func testMonochromeProfileWithShading() {
        XCTAssertEqual(
            CameraLookParsing.look(from: monoProfile3),
            "Monochrome Profile 3 | red filter str3 | grain Low | shading +5")
    }

    /// H1071740.JPG, the other arm of the shading A/B.
    func testNegativeShadingKeepsItsSign() {
        var metadata = monoProfile3
        metadata["Olympus:MonochromeVignetting"] = -5

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Monochrome Profile 3 | red filter str3 | grain Low | shading -5")
    }

    /// The no-ops that showed up on nearly every frame of the sample set — including
    /// `MonochromeColor` "Normal", which is the untoned default rather than a tint.
    func testMonochromeDefaultsAreSuppressed() {
        var metadata = monoProfile3
        metadata["Olympus:MonochromeProfileSettings"] = "No Filter; 0; 8; Strength 2; 0; 3"
        metadata["Olympus:FilmGrainEffect"] = "Off"
        metadata["Olympus:MonochromeVignetting"] = 0
        metadata["Olympus:MonochromeColor"] = "Normal"

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Monochrome Profile 3")
    }

    /// H1071766.JPG — a filter selected but left at strength 0 applies nothing, so it isn't
    /// recorded. Verified against pixels, not assumed: No Filter, Blue and Yellow all at strength 0
    /// produce the same colour-to-grey mapping to within 0.4%.
    func testFilterAtZeroStrengthIsSuppressed() {
        var metadata = monoProfile3
        metadata["Olympus:MonochromeProfileSettings"] = "Blue Filter; 0; 8; Strength 0; 0; 3"

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Monochrome Profile 3 | grain Low | shading +5")
    }

    /// H1071767.JPG — one step of strength is a real change and is kept.
    func testFilterAtStrengthOneIsReported() {
        var metadata = monoProfile3
        metadata["Olympus:MonochromeProfileSettings"] = "Blue Filter; 0; 8; Strength 1; 0; 3"

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Monochrome Profile 3 | blue filter str1 | grain Low | shading +5")
    }

    func testSepiaTintIsReported() {
        var metadata = monoProfile3
        metadata["Olympus:MonochromeColor"] = "Sepia"

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Monochrome Profile 3 | red filter str3 | grain Low | shading +5 | tint sepia")
    }

    /// The leading `Min -5; Max 5` is the slider range, not two dialled hues — reading it as data
    /// would prefix every profile with a bogus `Y-5 O+5`.
    func testColorProfileSkipsTheLeadingRangePair() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Profile 2; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 3; Orange 3; Orange-red 3; Red 1; Magenta 3; Violet -1; Blue 2; Blue-cyan 1; Cyan 4; Green-cyan 1; Green 0; Yellow-green 2",
            "Olympus:ToneLevel":
                "Highlights; 3; -7; 7; Shadows; -3; -7; 7; Midtones; 0; -7; 7; 0; 0; 0; 0",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Color Profile 2 | Y+3 O+3 Or+3 R+1 M+3 V-1 B+2 Bc+1 C+4 Gc+1 Yg+2 | HL+3 SH-3")
    }

    func testColorProfileWithEveryHueAtZeroDropsTheSegment() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Profile 1; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 0; Orange 0; Orange-red 0; Red 0; Magenta 0; Violet 0; Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Color Profile 1")
    }

    /// Strength is field 3, not field 1 — field 1 is the colour slider's minimum. H1071754.JPG.
    func testColorCreatorReadsColorAndStrength() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 10; 0; 29; Strength 2; -4; 3",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Color Creator | color 10 (purple) | vivid +2")
    }

    /// H1071755.JPG — ring position 0 with strength applied. Position 0 applies no hue but still
    /// runs as a pure saturation control, so it is a real setting rather than an unset default;
    /// suppressing it the way a zeroed hue slider is suppressed would lose that it was in use.
    func testColorCreatorPositionZeroIsNotSuppressed() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 0; 0; 29; Strength -1; -4; 3",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Color Creator | color 0 (neutral) | vivid -1")
    }

    /// The measured ring table (2026-08-09, H1071885-H1071915). Position 26 is the anchor the
    /// camera itself corroborates: its on-screen header swatch for that position is green.
    func testColorCreatorNamesTheRingPosition() {
        func look(_ position: Int) -> String {
            CameraLookParsing.look(from: [
                "Olympus:PictureMode": "Color Creator; 2",
                "Olympus:ColorCreatorEffect": "Color \(position); 0; 29; Strength -1; -4; 3",
            ])
        }

        XCTAssertEqual(look(26), "Color Creator | color 26 (green) | vivid -1")
        XCTAssertEqual(look(6), "Color Creator | color 6 (red) | vivid -1")
        XCTAssertEqual(look(15), "Color Creator | color 15 (blue) | vivid -1")
        XCTAssertEqual(look(29), "Color Creator | color 29 (lime) | vivid -1")
    }

    /// Vivid -4 renders fully desaturated whatever the ring position, and nothing else in the file
    /// says the frame is black and white — the picture mode still reads "Color Creator".
    func testColorCreatorAtLowestVividIsMarkedMono() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 26; 0; 29; Strength -4; -4; 3",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Color Creator | color 26 (green) | vivid -4 (mono)")
    }

    /// The position survives the mono annotation: the cast is applied before the desaturation, so it
    /// still decides which hues render light or dark the way a B&W contrast filter does. Dropping it
    /// would lose that.
    func testColorCreatorKeepsThePositionWhenMono() {
        func position(_ n: Int) -> String {
            CameraLookParsing.look(from: [
                "Olympus:PictureMode": "Color Creator; 2",
                "Olympus:ColorCreatorEffect": "Color \(n); 0; 29; Strength -4; -4; 3",
            ])
        }

        XCTAssertNotEqual(position(6), position(26))
        XCTAssertTrue(position(6).contains("color 6 (red)"))
        XCTAssertTrue(position(6).hasSuffix("vivid -4 (mono)"))
    }

    /// One step up from the bottom is not mono, so it keeps the plain signed form.
    func testColorCreatorJustAboveMonoIsNotMarked() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 26; 0; 29; Strength -3; -4; 3",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Color Creator | color 26 (green) | vivid -3")
    }

    /// The ring only runs to 29, but an out-of-range position falls back to the bare number rather
    /// than trapping on the table — same contract as `partialColorName`.
    func testColorCreatorPositionBeyondTheRingFallsBackToTheNumber() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 30; 0; 29; Strength -1; -4; 3",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Color Creator | color 30 (30) | vivid -1")
    }

    /// Strength 0 applies nothing whatever the channel, so both drop out. This is the state every
    /// non-Colour-Creator frame carries.
    func testColorCreatorAtZeroStrengthReportsModeOnly() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 28; 0; 29; Strength 0; -4; 3",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Color Creator")
    }

    /// H1071761.JPG — contrast dialled down within Monochrome Profile 4, which the same profile
    /// shot at 0 a few frames earlier. Per-profile, not a fixed per-mode default.
    func testProfileContrastIsReported() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Monochrome Profile 4; 2",
            "Olympus:PictureModeContrast": "-2 (min -2, max 2)",
            "Olympus:PictureModeSharpness": "0 (min -2, max 2)",
            "Olympus:PictureModeSaturation": "0 (min -2, max 2)",
            "Olympus:ToneLevel":
                "Highlights; -5; -7; 7; Shadows; -5; -7; 7; Midtones; -6; -7; 7; 0; 0; 0; 0",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Monochrome Profile 4 | contrast -2 | HL-5 SH-5 Mid-6")
    }

    /// H1071764.JPG — sharpness dialled up within Colour Profile 4.
    func testProfileSharpnessIsReported() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Art Mode; 2",
            "Olympus:PictureModeContrast": "0 (min -2, max 2)",
            "Olympus:PictureModeSharpness": "1 (min -2, max 2)",
            "Olympus:PictureModeSaturation": "0 (min -2, max 2)",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Color Profile 4 | sharp +1")
    }

    func testProfileContrastSharpnessSaturationAtZeroAreSuppressed() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Profile 1; 2",
            "Olympus:PictureModeContrast": "0 (min -2, max 2)",
            "Olympus:PictureModeSharpness": "0 (min -2, max 2)",
            "Olympus:PictureModeSaturation": "0 (min -2, max 2)",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Color Profile 1")
    }

    /// The unused padding after the three real tone channels must not be read as more channels.
    func testToneLevelPaddingIsIgnored() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Monochrome Profile 1; 2",
            "Olympus:ToneLevel":
                "Highlights; 0; -7; 7; Shadows; 0; -7; 7; Midtones; -2; -7; 7; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Monochrome Profile 1 | Mid-2")
    }

    /// A plain mode-dial look isn't a dialled-in look, so there is nothing to record — this is what
    /// keeps the Instructions field off every ordinary frame.
    func testPlainPictureModeProducesNothing() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 0; Orange 0; Orange-red 0; Red 0; Magenta 0; Violet 0; Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "")
    }

    func testEmptyMetadataProducesNothing() {
        XCTAssertEqual(CameraLookParsing.look(from: [:]), "")
    }

    /// An art filter is a look worth recording too, and it wins over `PictureMode` upstream.
    func testArtFilterIsCarried() {
        let metadata: [String: Any] = [
            "Olympus:ArtFilterEffect": "Dramatic Tone; Yes; 0",
            "Olympus:PictureMode": "Natural; 2",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Dramatic Tone")
    }

    // MARK: - Art filter stacked-option records
    //
    // Fixtures are real `exiftool -j -G1 -a -s` output from OM-3 frames shot to exercise one
    // setting at a time, except where noted as written to a scratch copy to reach a combination the
    // camera wasn't shot in.

    /// H1071780: Grainy Film with a green B&W contrast filter and a sepia tint. The filter record
    /// lands at field 4 here, so exiftool's colour-filter PrintConv on field 6 happens to be right.
    func testArtFilterBWFilterAndTintAreReported() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Grainy Film; 1280; 0; Partial Color 0; B&W; 1280; Green Color Filter; 0; 32880; 1280; 1; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Grainy Film | bw filter green | tint sepia")
    }

    /// H1071782 against H1071780: the tint is held at a different value while the filter moves
    /// green→yellow. Only the `0x8060` record changes, which is what establishes that the two
    /// records are independent stages rather than one setting.
    func testArtFilterFilterMovesWithoutDisturbingTheTint() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Grainy Film; 1280; 0; Partial Color 0; B&W; 1280; Yellow Color Filter; 0; 32880; 1280; 4; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Grainy Film | bw filter yellow | tint green")
    }

    /// H1071773: an effect *and* both stacked records, so the filter and tint sit at fields 8 and 12
    /// where exiftool applies no PrintConv at all and they arrive as bare numbers.
    func testArtFilterEffectAndBothStackedRecordsAreReported() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Grainy Film; 1280; 0; Partial Color 0; Frame; 4352; No Color Filter; 0; 32864; 1280; 2; 0; 32880; 1280; 3; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Grainy Film | fx Frame | bw filter orange | tint purple")
    }

    /// The reason the parser dispatches on the record code and never on the field position.
    ///
    /// Written to a scratch copy, because a tint with no contrast filter puts the `0x8070` record at
    /// field 4 — and exiftool then renders its value through the *colour-filter* table regardless.
    /// Value 3 is a purple tint but prints as "Red Color Filter", so reading field 6 at face value
    /// would report a red filter that was never set and lose the tint entirely.
    func testTintOnlyRecordIsNotMisreadAsAColorFilter() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Grainy Film; 1280; 0; Partial Color 0; Unknown (0x8070); 1280; Red Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        let look = CameraLookParsing.look(from: metadata)
        XCTAssertEqual(look, "Grainy Film | tint purple")
        XCTAssertFalse(look.contains("red"), look)
    }

    /// H1071772: partial colour is a real reading on a Partial Color filter.
    func testPartialColorIsReportedOnAPartialColorFilter() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Partial Color; 4352; 0; Partial Color 3; Star Light; 4352; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Partial Color | partial red | fx Star Light")
    }

    /// H1071792 and H1071801: two of the eighteen hue-wheel frames the ring mapping was measured
    /// from, at opposite ends of the ring. Stop 3 is red and stop 12 is its opposite, cyan.
    func testPartialColorStopsAreNamedFromTheMeasuredRing() {
        func look(stop: Int) -> String {
            CameraLookParsing.look(from: [
                "Olympus:PictureMode": "Natural; 2",
                "Olympus:ArtFilterEffect":
                    "Partial Color II; 4352; 0; Partial Color \(stop); No Effect; 0; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
            ])
        }

        XCTAssertEqual(look(stop: 0), "Partial Color II | partial yellow")
        XCTAssertEqual(look(stop: 3), "Partial Color II | partial red")
        XCTAssertEqual(look(stop: 12), "Partial Color II | partial cyan")
        XCTAssertEqual(look(stop: 17), "Partial Color II | partial chartreuse")
    }

    /// The ring has eighteen stops on every body seen so far, but the index is read straight from
    /// the file — an unexpected one falls back to the bare number rather than naming the wrong hue.
    func testPartialColorStopOutsideTheRingKeepsItsNumber() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Partial Color; 4352; 0; Partial Color 23; No Effect; 0; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Partial Color | partial 23")
    }

    /// The same stale-slot trap as the monochrome profile's leftover strength: H1071773 records
    /// "Partial Color 0" while on Grainy Film, which has no partial-colour setting at all. Gated on
    /// the filter's name, so a genuine "Partial Color 0" would still be reported.
    func testPartialColorIsSuppressedOnAFilterThatHasNone() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Grainy Film; 1280; 0; Partial Color 0; No Effect; 0; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Grainy Film")
    }

    /// Written to a scratch copy. A code outside exiftool's effect table must not silently vanish —
    /// it reports as hex so an unrecognised effect is visible rather than dropped, and a following
    /// record still parses.
    func testUnmappedStackedCodeIsReportedAsHex() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Grainy Film; 1280; 0; Partial Color 0; Unknown (0x80e8); 1280; Orange Color Filter; 0; 32864; 1280; 4; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Grainy Film | fx 0x80e8 | bw filter green")
    }

    /// H1071931/H1071930: the Shade Effect pair, which exiftool has no names for. Identified from
    /// the pixels rather than by extrapolating Blur's numbering — and the numbering does *not*
    /// extrapolate: Blur is top/bottom then left/right, Shade is left/right then top/bottom. See
    /// `CameraLookParsing.artEffectCodes` for the edge-luminance measurement.
    func testShadeEffectCodesAreNamedNotLeftAsHex() {
        var metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Vintage II; 4352; 0; Partial Color 0; Unknown (0x80a0); 4352; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]
        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Vintage II | fx Shade Left and Right")

        metadata["Olympus:ArtFilterEffect"] =
            "Vintage II; 4352; 0; Partial Color 0; Unknown (0x80a1); 4352; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0"
        XCTAssertEqual(
            CameraLookParsing.look(from: metadata), "Vintage II | fx Shade Top and Bottom")
    }

    /// H1071787: "Art 16" on the camera is filter ID 44, the last entry in exiftool's table, and it
    /// carries no options — so the filter name alone is the whole look.
    func testArtFilterWithNoOptionsReportsTheNameAlone() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ArtFilterEffect":
                "Instant Film; 4864; 0; Partial Color 0; No Effect; 0; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Instant Film")
    }

    // MARK: - Plain picture modes

    /// H1071784. Underwater is a distinct rendering, not a neutral default, so it is worth recording
    /// even with nothing else dialled.
    func testNonNaturalPlainModeIsReportedOnItsOwn() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Underwater; 2",
            "Olympus:PictureModeEffect": "Standard",
            "Olympus:Gradation": "Normal; User-Selected",
            "Olympus:ArtFilterEffect":
                "Off; 0; 0; Partial Color 0; No Effect; 0; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Underwater")
    }

    /// H1071785. Gradation's second component is independent of the first: the curve stays Normal
    /// while the camera overrides it automatically, so "grad auto" has to survive on its own.
    func testAutoGradationIsReportedWithoutACurveChange() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Monotone; 2",
            "Olympus:PictureModeBWFilter": "Neutral",
            "Olympus:PictureModeTone": "Neutral",
            "Olympus:Gradation": "Normal; Auto-Override",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Monotone | grad auto")
    }

    /// H1071786. The i-Enhance strength — the only frame out of 126 sampled that isn't Standard.
    /// Reached via the camera's Custom mode, which leaves no trace of itself in the file, so the
    /// base rendering it resolved to is what gets recorded.
    func testPictureModeEffectIsReported() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "i-Enhance; 2",
            "Olympus:PictureModeEffect": "High",
            "Olympus:Gradation": "Normal; User-Selected",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "i-Enhance | effect High")
    }

    /// H1071778: a plain mode carrying all three sliders and a tone curve. None of this was recorded
    /// before — the mode token was empty for plain modes, so the whole string was dropped.
    func testPlainModeSlidersAndHighKeyAreReported() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Muted; 2",
            "Olympus:PictureModeContrast": "2 (min -2, max 2)",
            "Olympus:PictureModeSharpness": "2 (min -2, max 2)",
            "Olympus:PictureModeSaturation": "2 (min -2, max 2)",
            "Olympus:PictureModeEffect": "Standard",
            "Olympus:Gradation": "High Key; User-Selected",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Muted | contrast +2 | sharp +2 | sat +2 | grad high key")
    }

    /// H1071779, the negative counterpart.
    func testPlainModeNegativeSlidersAndLowKeyAreReported() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Vivid; 2",
            "Olympus:PictureModeContrast": "-2 (min -2, max 2)",
            "Olympus:PictureModeSharpness": "-2 (min -2, max 2)",
            "Olympus:PictureModeSaturation": "-2 (min -2, max 2)",
            "Olympus:Gradation": "Low Key; User-Selected",
        ]

        XCTAssertEqual(
            CameraLookParsing.look(from: metadata),
            "Vivid | contrast -2 | sharp -2 | sat -2 | grad low key")
    }

    /// 24 of 118 archived frames are Natural with a tone curve dialled and nothing else. Those wrote
    /// an empty string before this change; Natural has to stop being silent once something is set.
    func testNaturalWithAToneCurveIsReported() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ToneLevel":
                "Highlights; 6; -7; 7; Shadows; -6; -7; 7; Midtones; 0; -7; 7; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Natural | HL+6 SH-6")
    }

    /// The other 94 must stay silent, which is what keeps Instructions off an ordinary frame.
    func testNaturalWithEverythingAtDefaultStaysSilent() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:PictureModeContrast": "0 (min -2, max 2)",
            "Olympus:PictureModeEffect": "Standard",
            "Olympus:PictureModeBWFilter": "n/a",
            "Olympus:PictureModeTone": "n/a",
            "Olympus:Gradation": "Normal; User-Selected",
            "Olympus:ToneLevel":
                "Highlights; 0; -7; 7; Shadows; 0; -7; 7; Midtones; 0; -7; 7; 0; 0; 0; 0; 0; 0; 0; 0",
            "Olympus:ArtFilterEffect":
                "Off; 0; 0; Partial Color 0; No Effect; 0; No Color Filter; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0",
            "Olympus:MonochromeProfileSettings": "No Filter; 0; 8; Strength 2; 0; 3",
            "Olympus:MonochromeColor": "(none)",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "")
    }

    /// H1071788, the third route carrying real values: Monotone's own filter and tint, which cover
    /// the same two option lists as the art-filter records but numbered one higher. They are read as
    /// text and never through `artBWFilters`/`artTints`, because sharing those tables would turn
    /// this frame's red filter into green (4 there is green, here it is red) and its blue tint into
    /// purple (3 there is purple, here it is blue).
    ///
    /// The frame also still carries a stale `MonochromeProfileSettings` strength of 2 from the
    /// monochrome-profile route it is not using — suppressed by that route's own "No Filter" guard.
    func testMonotoneFilterAndToneDoNotUseTheArtFilterNumbering() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Monotone; 2",
            "Olympus:PictureModeBWFilter": "Red",
            "Olympus:PictureModeTone": "Blue",
            "Olympus:Gradation": "Normal; Auto-Override",
            "Olympus:MonochromeProfileSettings": "No Filter; 0; 8; Strength 2; 0; 3",
            "Olympus:MonochromeColor": "(none)",
        ]

        let look = CameraLookParsing.look(from: metadata)
        XCTAssertEqual(look, "Monotone | bw filter red | tint blue | grad auto")
        XCTAssertFalse(look.contains("green"), look)
        XCTAssertFalse(look.contains("purple"), look)
        XCTAssertFalse(look.contains("str"), look)
    }

    /// Comfortably inside the legacy IPTC IIM 256-character cap even fully dialled in.
    func testFullyDialledLookStaysUnderTheIIMCap() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Art Mode; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow -5; Orange 5; Orange-red -5; Red 5; Magenta -5; Violet 5; Blue -5; Blue-cyan 5; Cyan -5; Green-cyan 5; Green -5; Yellow-green 5",
            "Olympus:ToneLevel":
                "Highlights; 7; -7; 7; Shadows; -7; -7; 7; Midtones; 7; -7; 7; 0; 0; 0; 0",
        ]

        let look = CameraLookParsing.look(from: metadata)
        XCTAssertTrue(look.hasPrefix("Color Profile 4 |"), look)
        XCTAssertLessThan(look.count, 256)
    }

    // MARK: - The typed reading

    /// The readings a visualiser needs are values, not substrings — a `-5` spoke has to arrive as
    /// `-5` rather than as the text `"Y-5"` for a wheel to be able to draw it.
    func testParseReturnsTypedValuesNotJustText() throws {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Art Mode; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow -5; Orange 0; Orange-red 0; Red 3; Magenta 0; Violet 0; Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
            "Olympus:ToneLevel": "Highlights; 7; -7; 7; Shadows; -2; -7; 7; Midtones; 0; -7; 7",
            "Olympus:PictureModeContrast": "-2 (min -2, max 2)",
            "Olympus:MonochromeVignetting": 1,
        ]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))

        XCTAssertEqual(look.mode, "Color Profile 4")
        // Only the dialled spokes, in the camera's own order, and zeroes dropped.
        XCTAssertEqual(look.hueSliders.map(\.code), ["Y", "R"])
        XCTAssertEqual(look.hueSliders.map(\.value), [-5, 3])
        XCTAssertEqual(look.toneLevels.map(\.code), ["HL", "SH"])
        XCTAssertEqual(look.toneLevels.map(\.value), [7, -2])
        XCTAssertEqual(look.contrast, -2)
        XCTAssertNil(look.sharpness)
        XCTAssertEqual(look.shading, 1)
    }

    /// The stacked art-filter records are packed in field order rather than sorted, so the typed
    /// list has to keep that order — see `testUnmappedStackedCodeIsReportedAsHex` for the frame
    /// where `fx` genuinely precedes the filter.
    func testParseKeepsStackedRecordsInFieldOrder() throws {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Art Mode; 2",
            "Olympus:ArtFilterEffect":
                "Grainy Film; 4352; 0; Partial Color 0; Unknown (0x80e8); 4352; No Color Filter; 0; 32864; 4352; 4; 0; 0; 0; 0; 0; 0; 0; 0; 0",
        ]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))

        XCTAssertEqual(look.artEffects, [.effect("0x80e8"), .bwFilter("green")])
        XCTAssertEqual(look.summary, "Grainy Film | fx 0x80e8 | bw filter green")
    }

    /// Colour Creator's -4 is the desaturated end of the range rather than an ordinary strength,
    /// and callers should be able to ask that directly instead of matching on the rendered text.
    func testParseFlagsTheMonochromeEndOfTheVividRange() throws {
        var metadata: [String: Any] = monoProfile3
        metadata["Olympus:PictureMode"] = "Color Creator; 2"
        metadata["Olympus:ColorCreatorEffect"] = "Color 10; 0; 29; Strength -4; -4; 3"

        let creator = try XCTUnwrap(CameraLookParsing.parse(from: metadata)?.colorCreator)

        XCTAssertEqual(creator.position, 10)
        XCTAssertEqual(creator.name, "purple")
        XCTAssertEqual(creator.strength, -4)
        XCTAssertTrue(creator.isMonochrome)
    }

    /// `parse` must go silent in exactly the cases `look` returns `""`, or a visualiser would draw
    /// a panel for an ordinary frame that had nothing dialled.
    func testParseIsNilExactlyWhereLookIsEmpty() {
        let untouched: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:ColorProfileSettings":
                "Min -5; Max 5; Yellow 0; Orange 0; Orange-red 0; Red 0; Magenta 0; Violet 0; Blue 0; Blue-cyan 0; Cyan 0; Green-cyan 0; Green 0; Yellow-green 0",
        ]

        XCTAssertNil(CameraLookParsing.parse(from: untouched))
        XCTAssertNil(CameraLookParsing.parse(from: [:]))

        // Natural is only silent while nothing is dialled — one reading and it reports again.
        var dialled = untouched
        dialled["Olympus:PictureModeSaturation"] = "2 (min -2, max 2)"
        XCTAssertEqual(CameraLookParsing.parse(from: dialled)?.summary, "Natural | sat +2")
    }

    /// The mode-only case is what `look` reports as a bare name, and a visualiser needs to tell it
    /// apart from a look carrying readings.
    func testModeOnlyLookIsDistinguishable() throws {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Muted; 2"]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))

        XCTAssertTrue(look.isModeOnly)
        XCTAssertTrue(look.segments.isEmpty)
        XCTAssertEqual(look.summary, "Muted")
    }

    // MARK: - White balance
    //
    // Fixture values are the real readings from H1072870-H1072875, shot one variable per frame with
    // the settings recorded at the camera before each exposure.

    /// H1072875: A+4, G+2. The asymmetric magnitudes are what prove the axis order — an equal pair
    /// reads the same whichever way round the values are.
    func testWhiteBalanceShiftIsReportedInTheCameraSOwnLetters() throws {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:WhiteBalanceBracket": "4 2",
        ]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))

        XCTAssertEqual(look.whiteBalanceShift?.blueAmber, 4)
        XCTAssertEqual(look.whiteBalanceShift?.magentaGreen, 2)
        XCTAssertEqual(look.summary, "Natural | wb A+4 G+2")
    }

    /// H1072871: B+4, M+4. Negative on both axes renders as the opposite pair of letters, never as a
    /// minus sign — the camera has no negative amounts on this dial.
    func testNegativeWhiteBalanceShiftRendersAsBlueAndMagenta() throws {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:WhiteBalanceBracket": "-4 -4",
        ]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))

        XCTAssertEqual(look.summary, "Natural | wb B+4 M+4")
    }

    /// An axis at zero is a default like any other reading, so only the dialled axis appears.
    func testZeroedAxisIsLeftOutOfTheShift() throws {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:WhiteBalanceBracket": "0 -3",
        ]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))

        XCTAssertEqual(look.summary, "Natural | wb M+3")
    }

    /// H1072870/H1072874: nothing dialled. A zeroed pair is the default state, so it must not turn
    /// an otherwise-silent Natural frame into an Instructions write.
    func testUnshiftedFrameReportsNothing() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:WhiteBalanceBracket": "0 0",
            "Olympus:WhiteBalance2": "Auto",
        ]

        XCTAssertNil(CameraLookParsing.parse(from: metadata))
    }

    /// A single value names no axis, so it is left alone rather than assigned to one. exiftool
    /// declares this tag as one `int16s`, and other bodies may well write it that way.
    func testSingleValuedShiftIsIgnored() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:WhiteBalanceBracket": "4",
        ]

        XCTAssertNil(CameraLookParsing.parse(from: metadata))
    }

    /// H1072871. Keep Warm Color off is the non-default, and the only reading this tag can give.
    func testKeepWarmColorOffIsReported() throws {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:WhiteBalance2": "Auto (Keep Warm Color Off)",
        ]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))

        XCTAssertTrue(look.keepWarmColorOff)
        XCTAssertEqual(look.summary, "Natural | wb warm off")
    }

    /// Under a preset or Custom WB the same tag carries the WB mode, where the warm-colour setting
    /// is simply not recoverable — so nothing is reported rather than a default that may be wrong.
    func testKeepWarmColorIsSilentUnderNonAutoWhiteBalance() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Natural; 2",
            "Olympus:WhiteBalance2": "5300K (Fine Weather)",
        ]

        XCTAssertNil(CameraLookParsing.parse(from: metadata))
    }

    /// The white balance readings sit after the look settings, so a dialled frame keeps its existing
    /// string and gains the shift on the end.
    func testWhiteBalanceFollowsTheLookSettings() throws {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Vivid; 2",
            "Olympus:PictureModeContrast": "1 (min -2, max 2)",
            "Olympus:WhiteBalanceBracket": "4 2",
            "Olympus:WhiteBalance2": "Auto (Keep Warm Color Off)",
        ]

        let look = try XCTUnwrap(CameraLookParsing.parse(from: metadata))

        XCTAssertEqual(look.summary, "Vivid | contrast +1 | wb A+4 G+2 | wb warm off")
    }
}
