import XCTest

@testable import MacPhotoMaster

final class TimelineLocationCacheTests: XCTestCase {
    private func makeCache(maxMatchSeconds: Int = 30 * 60) throws -> TimelineLocationCache {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("timeline_cache.sqlite3")
        return try TimelineLocationCache(databasePath: path, maxMatchSeconds: maxMatchSeconds)
    }

    private func sample(
        timestampUTC: Int,
        latitude: Double = 45.5,
        longitude: Double = -122.6,
        altitudeMeters: Double? = 30,
        accuracyMeters: Double? = 5,
        sourceType: String = "GPS"
    ) -> TimelineSample {
        TimelineSample(
            recordKey: TimelineSample.recordKey(
                timestampUTC: timestampUTC, latitude: latitude, longitude: longitude,
                altitudeMeters: altitudeMeters, sourceType: sourceType, accuracyMeters: accuracyMeters),
            timestampUTC: timestampUTC, latitude: latitude, longitude: longitude,
            altitudeMeters: altitudeMeters, accuracyMeters: accuracyMeters, sourceType: sourceType)
    }

    func testImportThenSuggestionReturnsNearestSampleWithinWindow() async throws {
        let cache = try makeCache()
        try await cache.importSamples(
            [sample(timestampUTC: 1_000), sample(timestampUTC: 1_500, latitude: 46.0)],
            sourcePath: "/tmp/Timeline.json", sourceSize: 100, sourceModificationNanoseconds: 1,
            sourceSHA256: "abc")

        let suggestion = try await cache.suggestion(forCaptureTimestampUTC: 1_050)

        XCTAssertEqual(suggestion?.matchedTimestampUTC, 1_000)
        XCTAssertEqual(suggestion?.ageSeconds, 50)
        XCTAssertEqual(suggestion?.latitude, 45.5)
    }

    func testSuggestionReturnsNilOutsideMatchWindow() async throws {
        let cache = try makeCache(maxMatchSeconds: 60)
        try await cache.importSamples(
            [sample(timestampUTC: 1_000)],
            sourcePath: "/tmp/Timeline.json", sourceSize: 100, sourceModificationNanoseconds: 1,
            sourceSHA256: "abc")

        let suggestion = try await cache.suggestion(forCaptureTimestampUTC: 1_200)

        XCTAssertNil(suggestion)
    }

    func testSuggestionPrefersMoreReliableSourceTypeOnEqualDistance() async throws {
        let cache = try makeCache()
        try await cache.importSamples(
            [
                sample(timestampUTC: 900, latitude: 1, sourceType: "WIFI"),
                sample(timestampUTC: 1_100, latitude: 2, sourceType: "GPS"),
            ],
            sourcePath: "/tmp/Timeline.json", sourceSize: 100, sourceModificationNanoseconds: 1,
            sourceSHA256: "abc")

        let suggestion = try await cache.suggestion(forCaptureTimestampUTC: 1_000)

        XCTAssertEqual(suggestion?.sourceType, "GPS")
        XCTAssertEqual(suggestion?.latitude, 2)
    }

    func testReimportingSameRecordKeyUpdatesRowInPlaceRatherThanDuplicating() async throws {
        let cache = try makeCache()
        let original = sample(timestampUTC: 1_000, accuracyMeters: 20)
        try await cache.importSamples(
            [original], sourcePath: "/tmp/Timeline.json", sourceSize: 100,
            sourceModificationNanoseconds: 1, sourceSHA256: "abc")

        var updated = original
        updated.accuracyMeters = 3
        try await cache.importSamples(
            [updated], sourcePath: "/tmp/Timeline.json", sourceSize: 100,
            sourceModificationNanoseconds: 1, sourceSHA256: "abc")

        let count = try await cache.positionCount()
        let suggestion = try await cache.suggestion(forCaptureTimestampUTC: 1_000)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(suggestion?.accuracyMeters, 3)
    }

    func testIsImportNeededFalseAfterMatchingSignatureAlreadyImported() async throws {
        let cache = try makeCache()
        let neededBeforeImport = try await cache.isImportNeeded(
            sourcePath: "/tmp/Timeline.json", sourceSize: 100, sourceModificationNanoseconds: 1)
        XCTAssertTrue(neededBeforeImport)

        try await cache.importSamples(
            [sample(timestampUTC: 1_000)], sourcePath: "/tmp/Timeline.json", sourceSize: 100,
            sourceModificationNanoseconds: 1, sourceSHA256: "abc")

        let neededAfterSameSignature = try await cache.isImportNeeded(
            sourcePath: "/tmp/Timeline.json", sourceSize: 100, sourceModificationNanoseconds: 1)
        let neededAfterDifferentSignature = try await cache.isImportNeeded(
            sourcePath: "/tmp/Timeline.json", sourceSize: 999, sourceModificationNanoseconds: 1)
        XCTAssertFalse(neededAfterSameSignature)
        XCTAssertTrue(neededAfterDifferentSignature)
    }
}
