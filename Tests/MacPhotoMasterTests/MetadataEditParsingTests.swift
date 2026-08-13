import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class MetadataEditParsingTests: XCTestCase {
    // MARK: - parseKeywords

    func testParseKeywordsSplitsAndTrimsCommaSeparatedList() {
        let keywords = MetadataEditParsing.parseKeywords(" sunset , beach,  ocean ")

        XCTAssertEqual(keywords, ["sunset", "beach", "ocean"])
    }

    func testParseKeywordsDropsEmptyEntries() {
        let keywords = MetadataEditParsing.parseKeywords("sunset,,  ,beach")

        XCTAssertEqual(keywords, ["sunset", "beach"])
    }

    func testParseKeywordsEmptyStringReturnsEmptyArray() {
        XCTAssertEqual(MetadataEditParsing.parseKeywords(""), [])
    }

    // MARK: - userAddedKeywords / merging

    func testUserAddedKeywordsReturnsOnlyWhatIsNotLoadedFromTheFile() {
        let added = MetadataEditParsing.userAddedKeywords(
            current: ["egret", "marsh", "great blue heron"], loaded: ["egret", "marsh"])

        XCTAssertEqual(added, ["great blue heron"])
    }

    func testUserAddedKeywordsMatchesLoadedKeywordsCaseInsensitively() {
        let added = MetadataEditParsing.userAddedKeywords(
            current: ["Egret", "great blue heron"], loaded: ["egret"])

        XCTAssertEqual(added, ["great blue heron"])
    }

    func testUserAddedKeywordsUnchangedBufferAddsNothing() {
        XCTAssertEqual(
            MetadataEditParsing.userAddedKeywords(current: ["egret", "marsh"], loaded: ["egret", "marsh"]), [])
    }

    func testMergingPutsUserKeywordsFirst() {
        let merged = MetadataEditParsing.merging(
            userAdded: ["great blue heron"], into: ["heron", "wading bird", "wetland"])

        XCTAssertEqual(merged, ["great blue heron", "heron", "wading bird", "wetland"])
    }

    func testMergingDoesNotDuplicateAKeywordTheModelAlreadyReturned() {
        let merged = MetadataEditParsing.merging(
            userAdded: ["great blue heron"], into: ["Great Blue Heron", "wetland"])

        XCTAssertEqual(merged, ["Great Blue Heron", "wetland"])
    }

    func testMergingNothingAddedLeavesTheModelListAlone() {
        XCTAssertEqual(MetadataEditParsing.merging(userAdded: [], into: ["heron", "wetland"]), ["heron", "wetland"])
    }

    // MARK: - parseGPS

    func testParseGPSValidLatitudeAndLongitudeReusesGivenAltitude() {
        let gps = MetadataEditParsing.parseGPS(latitudeText: "12.3456", longitudeText: "-98.7654", altitude: 42.0)

        XCTAssertEqual(gps, GPSCoordinate(latitude: 12.3456, longitude: -98.7654, altitude: 42.0))
    }

    func testParseGPSBlankLatitudeReturnsNil() {
        let gps = MetadataEditParsing.parseGPS(latitudeText: "  ", longitudeText: "-98.7654", altitude: nil)

        XCTAssertNil(gps)
    }

    func testParseGPSBlankLongitudeReturnsNil() {
        let gps = MetadataEditParsing.parseGPS(latitudeText: "12.3456", longitudeText: "", altitude: nil)

        XCTAssertNil(gps)
    }

    func testParseGPSUnparseableTextReturnsNil() {
        let gps = MetadataEditParsing.parseGPS(latitudeText: "north", longitudeText: "-98.7654", altitude: nil)

        XCTAssertNil(gps)
    }
}
