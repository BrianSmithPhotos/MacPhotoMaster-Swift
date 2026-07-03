import XCTest

@testable import MacPhotoMaster

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
