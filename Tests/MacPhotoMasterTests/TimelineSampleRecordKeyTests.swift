import XCTest

@testable import MacPhotoMasterCore

/// The record key is stored in the location cache and is what `isImportNeeded`/`importSamples` use
/// to tell a re-import from new data, so its exact text is a persisted format, not an implementation
/// detail. These expectations are SHA-1 digests computed independently (Python `hashlib`) of the
/// documented field string, so a rewrite for speed cannot quietly change what the cache already
/// holds and re-import an unchanged export as a folder full of new points.
final class TimelineSampleRecordKeyTests: XCTestCase {
    func testKeyForAFullyPopulatedSampleMatchesTheStoredFormat() {
        let key = TimelineSample.recordKey(
            timestampUTC: 1_600_000_000, latitude: 51.5, longitude: -1.2, altitudeMeters: 42,
            sourceType: "WIFI", accuracyMeters: 8)

        // SHA-1 of "1600000000|51.5000000|-1.2000000|42.000|WIFI|8.000"
        XCTAssertEqual(key, "8679e34b8975308fabe2d7e5ae725e8cdbfebb11")
    }

    /// A `timelinePath` point has neither altitude nor accuracy — both slots stay empty rather than
    /// carrying a zero, which would collide with a genuinely sea-level reading.
    func testKeyWithNoAltitudeOrAccuracyLeavesThoseFieldsEmpty() {
        let key = TimelineSample.recordKey(
            timestampUTC: 1_600_000_000, latitude: 51.5, longitude: -1.2, altitudeMeters: nil,
            sourceType: "TIMELINE_PATH", accuracyMeters: nil)

        // SHA-1 of "1600000000|51.5000000|-1.2000000||TIMELINE_PATH|"
        XCTAssertEqual(key, "40be3048b267d5258e8dac477cc044e34fb038d3")
    }
}
