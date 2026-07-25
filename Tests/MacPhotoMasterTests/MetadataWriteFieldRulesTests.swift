import XCTest

@testable import MacPhotoMasterCore

final class MetadataWriteFieldRulesTests: XCTestCase {
    func testParsesDisplayDistanceIntoMetres() {
        XCTAssertEqual(MetadataWriteFieldRules.subjectDistanceMeters(from: "16.03 m"), 16.03)
        XCTAssertEqual(MetadataWriteFieldRules.subjectDistanceMeters(from: "2.5 m"), 2.5)
    }

    func testAcceptsBarePlainNumberWithoutUnit() {
        XCTAssertEqual(MetadataWriteFieldRules.subjectDistanceMeters(from: "7.2"), 7.2)
    }

    func testRejectsBlankInfinityAndZero() {
        // A blank field (nothing focused/read), "inf" (focused at infinity), and 0 are all
        // meaningless as a fixed subject distance, so none should be written out.
        XCTAssertNil(MetadataWriteFieldRules.subjectDistanceMeters(from: ""))
        XCTAssertNil(MetadataWriteFieldRules.subjectDistanceMeters(from: "   "))
        XCTAssertNil(MetadataWriteFieldRules.subjectDistanceMeters(from: "inf"))
        XCTAssertNil(MetadataWriteFieldRules.subjectDistanceMeters(from: "inf m"))
        XCTAssertNil(MetadataWriteFieldRules.subjectDistanceMeters(from: "0"))
        XCTAssertNil(MetadataWriteFieldRules.subjectDistanceMeters(from: "0.00 m"))
    }
}
