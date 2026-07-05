import XCTest

@testable import MacPhotoMaster

final class EBirdCacheTests: XCTestCase {
    private func makeCache() throws -> EBirdCache {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("ebird_cache.sqlite3")
        return try EBirdCache(databasePath: path)
    }

    // MARK: - Taxonomy

    func testTaxonomyFetchedAtNilBeforeAnyReplace() async throws {
        let cache = try makeCache()

        let fetchedAt = try await cache.taxonomyFetchedAt()
        XCTAssertNil(fetchedAt)
    }

    func testReplaceTaxonomyThenFetchedAtIsRecent() async throws {
        let cache = try makeCache()

        try await cache.replaceTaxonomy([
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species")
        ])

        let fetchedAt = try await cache.taxonomyFetchedAt()
        XCTAssertNotNil(fetchedAt)
        XCTAssertEqual(fetchedAt!.timeIntervalSinceNow, 0.0, accuracy: 5.0)
    }

    func testReplaceTaxonomyDropsRowsFromThePreviousReplace() async throws {
        let cache = try makeCache()
        try await cache.replaceTaxonomy([
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species")
        ])

        try await cache.replaceTaxonomy([
            EBirdTaxonEntry(
                speciesCode: "houfin", commonName: "House Finch", scientificName: "Haemorhous mexicanus",
                category: "species")
        ])

        let entries = try await cache.taxonomyEntries(forSpeciesCodes: ["comrav", "houfin"])
        XCTAssertEqual(entries.map(\.speciesCode), ["houfin"])
    }

    func testTaxonomyEntriesOmitsUnmatchedCodes() async throws {
        let cache = try makeCache()
        try await cache.replaceTaxonomy([
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species")
        ])

        let entries = try await cache.taxonomyEntries(forSpeciesCodes: ["comrav", "nosuchcode"])

        XCTAssertEqual(entries, [
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species")
        ])
    }

    func testTaxonomyEntriesReturnsEmptyForEmptyInput() async throws {
        let cache = try makeCache()

        let entries = try await cache.taxonomyEntries(forSpeciesCodes: [])

        XCTAssertEqual(entries, [])
    }

    // MARK: - Region species lists

    func testCachedSpeciesCodesNilBeforeAnyStore() async throws {
        let cache = try makeCache()

        let result = try await cache.cachedSpeciesCodes(regionCode: "US-CA-041")
        XCTAssertNil(result)
    }

    func testStoreThenCachedSpeciesCodesRoundTrips() async throws {
        let cache = try makeCache()

        try await cache.storeSpeciesCodes(["comrav", "houfin"], regionCode: "US-CA-041")
        let result = try await cache.cachedSpeciesCodes(regionCode: "US-CA-041")

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.codes, ["comrav", "houfin"])
        XCTAssertEqual(unwrapped.fetchedAt.timeIntervalSinceNow, 0.0, accuracy: 5.0)
    }

    func testStoreOverwritesPreviousValueForSameRegionCode() async throws {
        let cache = try makeCache()

        try await cache.storeSpeciesCodes(["comrav"], regionCode: "US-CA-041")
        try await cache.storeSpeciesCodes(["houfin"], regionCode: "US-CA-041")
        let result = try await cache.cachedSpeciesCodes(regionCode: "US-CA-041")

        XCTAssertEqual(result?.codes, ["houfin"])
    }

    func testDifferentRegionCodesAreCachedIndependently() async throws {
        let cache = try makeCache()

        try await cache.storeSpeciesCodes(["comrav"], regionCode: "US-CA-041")
        try await cache.storeSpeciesCodes(["houfin"], regionCode: "US-OR-051")

        let caResult = try await cache.cachedSpeciesCodes(regionCode: "US-CA-041")
        let orResult = try await cache.cachedSpeciesCodes(regionCode: "US-OR-051")
        XCTAssertEqual(caResult?.codes, ["comrav"])
        XCTAssertEqual(orResult?.codes, ["houfin"])
    }
}
