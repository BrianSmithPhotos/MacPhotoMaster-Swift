import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class TimelineImportParserTests: XCTestCase {
    private let parser = TimelineImportParser()

    func testParsesRawSignalPositionWithFullFields() throws {
        let json = """
            {
                "rawSignals": [
                    {
                        "position": {
                            "LatLng": "45.5000000\u{b0}, -122.6000000\u{b0}",
                            "timestamp": "2026-03-15T14:30:00.000Z",
                            "altitudeMeters": 30.5,
                            "accuracyMeters": 5.0,
                            "source": "GPS"
                        }
                    }
                ]
            }
            """

        let samples = try parser.parseSamples(from: Data(json.utf8))

        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.latitude, 45.5, accuracy: 0.0001)
        XCTAssertEqual(sample.longitude, -122.6, accuracy: 0.0001)
        XCTAssertEqual(sample.altitudeMeters, 30.5)
        XCTAssertEqual(sample.accuracyMeters, 5.0)
        XCTAssertEqual(sample.sourceType, "GPS")
        XCTAssertEqual(sample.timestampUTC, 1_773_585_000)
    }

    func testParsesSemanticSegmentTimelinePathPointAsTimelinePathSource() throws {
        let json = """
            {
                "semanticSegments": [
                    {
                        "timelinePath": [
                            {
                                "point": "45.6000000\u{b0}, -122.7000000\u{b0}",
                                "time": "2026-03-15T15:00:00.000Z"
                            }
                        ]
                    }
                ]
            }
            """

        let samples = try parser.parseSamples(from: Data(json.utf8))

        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.sourceType, "TIMELINE_PATH")
        XCTAssertNil(sample.altitudeMeters)
        XCTAssertNil(sample.accuracyMeters)
    }

    func testDeduplicatesIdenticalRecordsAcrossRepeatedEntries() throws {
        let json = """
            {
                "rawSignals": [
                    {
                        "position": {
                            "LatLng": "45.5\u{b0}, -122.6\u{b0}",
                            "timestamp": "2026-03-15T14:30:00Z",
                            "source": "GPS"
                        }
                    },
                    {
                        "position": {
                            "LatLng": "45.5\u{b0}, -122.6\u{b0}",
                            "timestamp": "2026-03-15T14:30:00Z",
                            "source": "GPS"
                        }
                    }
                ]
            }
            """

        let samples = try parser.parseSamples(from: Data(json.utf8))

        XCTAssertEqual(samples.count, 1)
    }

    func testSkipsMalformedEntriesButKeepsValidOnes() throws {
        let json = """
            {
                "rawSignals": [
                    { "position": { "LatLng": "not a coordinate", "timestamp": "2026-03-15T14:30:00Z" } },
                    { "position": { "LatLng": "45.5\u{b0}, -122.6\u{b0}" } },
                    { "position": { "LatLng": "45.5\u{b0}, -122.6\u{b0}", "timestamp": "2026-03-15T14:30:00Z" } }
                ]
            }
            """

        let samples = try parser.parseSamples(from: Data(json.utf8))

        XCTAssertEqual(samples.count, 1)
    }

    func testMissingSourceDefaultsToUnknown() throws {
        let json = """
            {
                "rawSignals": [
                    {
                        "position": {
                            "LatLng": "45.5\u{b0}, -122.6\u{b0}",
                            "timestamp": "2026-03-15T14:30:00Z"
                        }
                    }
                ]
            }
            """

        let samples = try parser.parseSamples(from: Data(json.utf8))

        XCTAssertEqual(samples.first?.sourceType, "UNKNOWN")
    }

    func testTimestampWithoutOffsetIsAssumedUTC() throws {
        let json = """
            {
                "rawSignals": [
                    {
                        "position": {
                            "LatLng": "45.5\u{b0}, -122.6\u{b0}",
                            "timestamp": "2026-03-15T14:30:00",
                            "source": "GPS"
                        }
                    }
                ]
            }
            """

        let samples = try parser.parseSamples(from: Data(json.utf8))

        XCTAssertEqual(samples.first?.timestampUTC, 1_773_585_000)
    }

    func testThrowsNoPositionRecordsWhenPayloadHasNoUsableEntries() {
        let json = "{}"

        XCTAssertThrowsError(try parser.parseSamples(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? TimelineImportError, .noPositionRecords)
        }
    }

    func testThrowsInvalidJSONForNonJSONData() {
        let data = Data("not json".utf8)

        XCTAssertThrowsError(try parser.parseSamples(from: data)) { error in
            XCTAssertEqual(error as? TimelineImportError, .invalidJSON)
        }
    }
}
