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

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Color Creator | color 10 | strength +2")
    }

    /// H1071755.JPG — colour channel 0 with strength applied. Colour Creator adjusts one of 30
    /// channels, so 0 is a real channel index, not an unset default; suppressing it the way a
    /// zeroed hue slider is suppressed would lose which channel was actually adjusted.
    func testColorCreatorChannelZeroIsNotSuppressed() {
        let metadata: [String: Any] = [
            "Olympus:PictureMode": "Color Creator; 2",
            "Olympus:ColorCreatorEffect": "Color 0; 0; 29; Strength -1; -4; 3",
        ]

        XCTAssertEqual(CameraLookParsing.look(from: metadata), "Color Creator | color 0 | strength -1")
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
}
