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

    /// The timestamp scanner (`epochSecondsScanningISO8601`) stands in front of the date formatters
    /// because they cost more than the rest of the parse put together, so every shape an export can
    /// carry has to come out with the same epoch seconds the formatters produced. A wrong offset
    /// here would put a photo's suggested location an hour's driving away from where it was taken.
    func testTimestampOffsetsAndFractionsAllResolveToTheSameInstant() throws {
        let shapes = [
            "2026-03-15T14:30:00Z", "2026-03-15T14:30:00.000Z", "2026-03-15T14:30:00.123456Z",
            "2026-03-15T15:30:00+01:00", "2026-03-15T09:30:00-05:00", "2026-03-15T14:30:00",
        ]

        for shape in shapes {
            let json = """
                {"rawSignals": [{"position": {"LatLng": "45.5\u{b0}, -122.6\u{b0}", "timestamp": "\(shape)"}}]}
                """
            let samples = try parser.parseSamples(from: Data(json.utf8))
            XCTAssertEqual(samples.first?.timestampUTC, 1_773_585_000, "for \(shape)")
        }
    }

    /// Text the scanner cannot read must fall through to the formatters and, failing those, be
    /// skipped — never guessed at. A month of 13 is corrupt data, not December of the next year.
    func testUnparseableTimestampsAreSkippedRatherThanGuessed() {
        let json = """
            {
                "rawSignals": [
                    {"position": {"LatLng": "45.5\u{b0}, -122.6\u{b0}", "timestamp": "2026-13-15T14:30:00Z"}},
                    {"position": {"LatLng": "45.5\u{b0}, -122.6\u{b0}", "timestamp": "15/03/2026 14:30"}},
                    {"position": {"LatLng": "45.5\u{b0}, -122.6\u{b0}", "timestamp": "2026-03-15T14:30"}}
                ]
            }
            """

        XCTAssertThrowsError(try parser.parseSamples(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? TimelineImportError, .noPositionRecords)
        }
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
