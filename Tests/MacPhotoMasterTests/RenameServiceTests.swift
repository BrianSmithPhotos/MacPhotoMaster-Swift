import XCTest

@testable import MacPhotoMaster

final class RenameServiceTests: XCTestCase {
    /// Parses the same way `NativeMetadataReader.parseExifDate` does, so the resulting `Date`
    /// round-trips back to the same wall-clock digits in the filename.
    private func exifDate(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: text)!
    }

    func testBuildFilenameMatchesReferenceAppPattern() {
        // Fixture pinned by the Python reference app's test_rename_service.py, so the ported
        // Swift output is byte-for-byte comparable.
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042.JPG"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "OM-1",
            lensModel: "12-40mm F2.8",
            batch: "Yosemite",
            artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)

        XCTAssertEqual(filename, "1010042_Yosemite_20260621_1405_OM-1_12-40mm-F2.8.jpg")
    }

    func testBuildFilenameOmitsBatchSegmentWhenEmpty() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042.JPG"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "OM-1", lensModel: "12-40mm F2.8", batch: "", artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)

        XCTAssertEqual(filename, "1010042_20260621_1405_OM-1_12-40mm-F2.8.jpg")
    }

    func testBuildFilenameIncludesArtFilterSegmentWhenPresent() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042.JPG"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "OM-1", lensModel: "12-40mm F2.8", batch: "",
            artFilterToken: "Dramatic Tone")

        let filename = RenameService().buildFilename(for: context)

        XCTAssertEqual(filename, "1010042_20260621_1405_Dramatic-Tone_OM-1_12-40mm-F2.8.jpg")
    }

    func testBuildFilenameFallsBackToUnknownCameraAndLensWhenBlank() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042.JPG"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "", lensModel: "  ", batch: "", artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)

        XCTAssertEqual(filename, "1010042_20260621_1405_UnknownCamera_UnknownLens.jpg")
    }

    func testBuildFilenameFallsBackToUnknownDateAndTimeWhenCapturedAtIsMissing() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042.JPG"),
            capturedAt: nil, cameraModel: "OM-1", lensModel: "12-40mm F2.8", batch: "",
            artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)

        XCTAssertEqual(filename, "1010042_UnknownDate_UnknownTime_OM-1_12-40mm-F2.8.jpg")
    }

    func testSequenceIsZeroWhenSourceFilenameHasNoDigits() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/IMG.JPG"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "OM-1", lensModel: "12-40mm F2.8", batch: "", artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)

        XCTAssertTrue(filename.hasPrefix("0_"))
    }

    func testSanitizeReplacesInvalidCharactersAndCollapsesWhitespaceToASingleDash() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042.JPG"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "OM-1", lensModel: "12-40mm F2.8",
            batch: "Big Sur/Highway  1", artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)

        XCTAssertEqual(filename, "1010042_Big-Sur-Highway-1_20260621_1405_OM-1_12-40mm-F2.8.jpg")
    }

    func testSanitizeTruncatesComponentsLongerThan64Characters() {
        let longBatch = String(repeating: "a", count: 100)
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042.JPG"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "OM-1", lensModel: "12-40mm F2.8", batch: longBatch,
            artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)
        let batchSegment = filename.split(separator: "_")[1]

        XCTAssertEqual(batchSegment.count, 64)
    }

    func testExtensionIsLowercasedAndRawExtensionsArePreservedNotConvertedToJPG() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042.ORF"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "OM-1", lensModel: "12-40mm F2.8", batch: "", artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)

        XCTAssertTrue(filename.hasSuffix(".orf"))
    }

    func testExtensionDefaultsToJPGWhenSourceHasNone() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1010042"),
            capturedAt: exifDate("2026:06:21 14:05:30"),
            cameraModel: "OM-1", lensModel: "12-40mm F2.8", batch: "", artFilterToken: nil)

        let filename = RenameService().buildFilename(for: context)

        XCTAssertTrue(filename.hasSuffix(".jpg"))
    }

    func testEnsureUniqueNameReturnsCandidateUnchangedWhenNoCollision() {
        let result = RenameService().ensureUniqueName("photo.jpg", existingNames: [])
        XCTAssertEqual(result, "photo.jpg")
    }

    func testEnsureUniqueNameAppendsIncrementingSuffixUntilNoCollision() {
        let existing: Set<String> = ["photo.jpg", "photo_1.jpg", "photo_2.jpg"]
        let result = RenameService().ensureUniqueName("photo.jpg", existingNames: existing)
        XCTAssertEqual(result, "photo_3.jpg")
    }
}
