import XCTest

@testable import MacPhotoMaster

final class ElevationLookupServiceTests: XCTestCase {
    // Fixtures shaped like the reference app's known USGS EPQS response variants
    // (elevation_lookup_service.py's `_extract_value`).

    func testExtractsDirectValueField() {
        let payload: [String: Any] = ["value": "123.45"]

        XCTAssertEqual(ElevationLookupService.extractValue(from: payload), 123.45)
    }

    func testExtractsNestedUSGSElevationQueryField() {
        let payload: [String: Any] = [
            "USGS_Elevation_Point_Query_Service": [
                "Elevation_Query": [
                    "Elevation": 456.7
                ]
            ]
        ]

        XCTAssertEqual(ElevationLookupService.extractValue(from: payload), 456.7)
    }

    func testExtractsFlatElevationField() {
        let payload: [String: Any] = ["elevation": 78.9]

        XCTAssertEqual(ElevationLookupService.extractValue(from: payload), 78.9)
    }

    func testReturnsNilForUnrecognizedShape() {
        let payload: [String: Any] = ["somethingElse": 1]

        XCTAssertNil(ElevationLookupService.extractValue(from: payload))
    }
}
