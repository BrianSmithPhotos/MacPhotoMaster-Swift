import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class ArtFilterTokenParsingTests: XCTestCase {
    // Fixtures pinned by the Python reference app's test_exif_service.py art-filter-token tests,
    // so the ported Swift output is byte-for-byte comparable.

    func testPrefersActiveArtFilterEffect() {
        let metadata: [String: Any] = ["Olympus:ArtFilterEffect": "Dramatic Tone; Yes; 0"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Dramatic Tone")
    }

    func testIgnoresOffArtFilterEffect() {
        let metadata: [String: Any] = ["Olympus:ArtFilterEffect": "Off"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "")
    }

    func testFallsBackToPictureModeProfile() {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Color Profile 1"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Color Profile 1")
    }

    /// Colour Creator is a creative-dial position like the profiles, but its name doesn't contain
    /// "profile" — it produced no filename segment at all before.
    func testFallsBackToPictureModeColorCreator() {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Color Creator; 2"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Color Creator")
    }

    /// `PictureMode` 17 prints as "Art Mode" but is Colour Profile 4 on the OM-3 — remapped here,
    /// which is safe because a genuine art filter returns from the `ArtFilterEffect` branch first.
    func testArtModeIsRemappedToColorProfile4() {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Art Mode; 2"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Color Profile 4")
    }

    func testActiveArtFilterStillWinsOverArtModePictureMode() {
        let metadata: [String: Any] = [
            "Olympus:ArtFilterEffect": "Grainy Film; Yes; 0",
            "Olympus:PictureMode": "Art Mode; 2",
        ]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Grainy Film")
    }

    func testPlainPictureModeIsNotAToken() {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Natural; 2"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "")
    }

    func testFallsBackToStackedImageState() {
        let metadata: [String: Any] = ["Olympus:StackedImage": "Live Composite"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Live Composite")
    }

    func testFallsBackToMultipleExposureMode() {
        let metadata: [String: Any] = ["Olympus:MultipleExposureMode": "On (2 Shots)"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "MultipleExposure")
    }

    func testNoMatchingTagsReturnsEmptyString() {
        XCTAssertEqual(ArtFilterTokenParsing.token(from: [:]), "")
    }

    func testStackedImageNoIsIgnored() {
        let metadata: [String: Any] = ["Olympus:StackedImage": "No"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "")
    }
}
