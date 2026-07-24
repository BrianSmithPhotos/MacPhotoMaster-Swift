import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class IPadExportNameParsingTests: XCTestCase {
    func testParsesSequenceWhenNoBatchSegmentPresent() {
        let parsed = IPadExportNameParsing.parse(filename: "1010042_20260621_1405_OM-1_12-40mm-F2.8.orf")

        XCTAssertEqual(parsed, IPadExportNameParsing.Parsed(sequence: "1010042", batch: ""))
    }

    func testParsesSingleSegmentBatch() {
        let parsed = IPadExportNameParsing.parse(filename: "1010042_Yosemite_20260621_1405_OM-1_12-40mm-F2.8.orf")

        XCTAssertEqual(parsed, IPadExportNameParsing.Parsed(sequence: "1010042", batch: "Yosemite"))
    }

    /// `RenameService.sanitizeComponent` replaces whitespace with `-` but leaves `_` alone, so a
    /// typed batch label can contain the same separator the filename is built from.
    func testParsesBatchContainingSeparator() {
        let parsed = IPadExportNameParsing.parse(filename: "1010042_dawn_walk_20260621_1405_OM-1_12-40mm.orf")

        XCTAssertEqual(parsed, IPadExportNameParsing.Parsed(sequence: "1010042", batch: "dawn_walk"))
    }

    /// The whole point of the re-parse is to insert this segment, but re-importing an already
    /// enriched name must not shift the anchor — it sits after the date/time pair, not before it.
    func testArtFilterSegmentDoesNotAffectParsing() {
        let parsed = IPadExportNameParsing.parse(
            filename: "1010042_Yosemite_20260621_1405_Dramatic-Tone_OM-1_12-40mm.orf")

        XCTAssertEqual(parsed, IPadExportNameParsing.Parsed(sequence: "1010042", batch: "Yosemite"))
    }

    /// Lens names routinely carry dots (`F5.0-6.3`), so stripping the extension has to take only the
    /// last one — an earlier naive split would truncate the stem mid-lens.
    func testLensSegmentWithDotsDoesNotConfuseExtensionStripping() {
        let parsed = IPadExportNameParsing.parse(
            filename: "1010042_20260621_1405_OM-1_M-Zuiko-ED-100-400mm-F5.0-6.3-IS.orf")

        XCTAssertEqual(parsed, IPadExportNameParsing.Parsed(sequence: "1010042", batch: ""))
    }

    /// A file whose capture timestamp couldn't be read still gets processed, under
    /// `RenameService.dateTimeParts`'s literal placeholders — it has to stay importable.
    func testParsesUnknownDateTimePlaceholders() {
        let parsed = IPadExportNameParsing.parse(filename: "1010042_UnknownDate_UnknownTime_OM-1_12-40mm.orf")

        XCTAssertEqual(parsed, IPadExportNameParsing.Parsed(sequence: "1010042", batch: ""))
    }

    /// Only an 8-digit segment immediately followed by a 4-digit one anchors the date/time, so a
    /// numeric batch label is still read as part of the batch.
    func testNumericBatchIsNotMistakenForDate() {
        let parsed = IPadExportNameParsing.parse(filename: "1010042_2026_20260621_1405_OM-1_12-40mm.orf")

        XCTAssertEqual(parsed, IPadExportNameParsing.Parsed(sequence: "1010042", batch: "2026"))
    }

    func testRejectsCameraOriginalFilename() {
        XCTAssertNil(IPadExportNameParsing.parse(filename: "P1010042.ORF"))
    }

    func testRejectsFilenameWithNonNumericLeadingSegment() {
        XCTAssertNil(IPadExportNameParsing.parse(filename: "IMG_20260621_1405_OM-1_12-40mm.jpg"))
    }

    func testRejectsFilenameWithNoDateTimePair() {
        XCTAssertNil(IPadExportNameParsing.parse(filename: "1010042_Yosemite_OM-1.orf"))
    }
}
