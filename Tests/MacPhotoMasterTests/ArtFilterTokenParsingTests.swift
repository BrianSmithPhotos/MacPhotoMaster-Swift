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
