import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class ElevationCacheTests: XCTestCase {
    private func makeCache() throws -> ElevationCache {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("elevation_cache.sqlite3")
        return try ElevationCache(databasePath: path)
    }

    func testCachedElevationNilBeforeAnyStore() async throws {
        let cache = try makeCache()

        let elevation = try await cache.cachedElevation(latitude: 45.5, longitude: -122.6)

        XCTAssertNil(elevation)
    }

    func testStoreThenCachedElevationRoundTrips() async throws {
        let cache = try makeCache()

        try await cache.store(latitude: 45.5, longitude: -122.6, elevationMeters: 123.4)
        let elevation = try await cache.cachedElevation(latitude: 45.5, longitude: -122.6)

        XCTAssertEqual(elevation, 123.4)
    }

    func testCoordinatesRoundingToSameKeyShareCachedValue() async throws {
        let cache = try makeCache()

        try await cache.store(latitude: 45.50001, longitude: -122.60001, elevationMeters: 55.0)
        let elevation = try await cache.cachedElevation(latitude: 45.50002, longitude: -122.60002)

        XCTAssertEqual(elevation, 55.0)
    }

    func testStoreOverwritesPreviousValueForSameKey() async throws {
        let cache = try makeCache()

        try await cache.store(latitude: 45.5, longitude: -122.6, elevationMeters: 10.0)
        try await cache.store(latitude: 45.5, longitude: -122.6, elevationMeters: 20.0)
        let elevation = try await cache.cachedElevation(latitude: 45.5, longitude: -122.6)

        XCTAssertEqual(elevation, 20.0)
    }
}
