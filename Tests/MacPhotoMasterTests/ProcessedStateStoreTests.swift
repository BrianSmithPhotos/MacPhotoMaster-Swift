import XCTest

@testable import MacPhotoMaster

final class ProcessedStateStoreTests: XCTestCase {
    private func makeStore() throws -> ProcessedStateStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("processed_state.sqlite3")
        return try ProcessedStateStore(databasePath: path)
    }

    func testProcessedPathIsReturnedByQuery() async throws {
        let store = try makeStore()

        try await store.markProcessed(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")

        let processed = try await store.processedAssetPaths(inFolder: "/card/DCIM/100")
        XCTAssertEqual(processed, ["/card/DCIM/100/a.jpg"])
    }

    func testMarkingTheSamePathProcessedTwiceDoesNotDuplicateOrThrow() async throws {
        let store = try makeStore()

        try await store.markProcessed(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")
        try await store.markProcessed(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")

        let processed = try await store.processedAssetPaths(inFolder: "/card/DCIM/100")
        XCTAssertEqual(processed, ["/card/DCIM/100/a.jpg"])
    }

    func testProcessedStateIsScopedPerFolderNotGlobal() async throws {
        let store = try makeStore()
        try await store.markProcessed(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")

        let processedElsewhere = try await store.processedAssetPaths(inFolder: "/card/DCIM/200")
        XCTAssertTrue(processedElsewhere.isEmpty)
    }

    func testMarkingMultiplePathsAtOnceMarksAllOfThem() async throws {
        // Mirrors processing a whole capture set: every member path marked in one call.
        let store = try makeStore()
        let paths = ["/card/DCIM/100/a.jpg", "/card/DCIM/100/a.orf"]

        try await store.markProcessed(assetPaths: paths, inFolder: "/card/DCIM/100")

        let processed = try await store.processedAssetPaths(inFolder: "/card/DCIM/100")
        XCTAssertEqual(processed, Set(paths))
    }
}
