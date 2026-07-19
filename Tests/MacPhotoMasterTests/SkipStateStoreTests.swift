import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class SkipStateStoreTests: XCTestCase {
    private func makeStore() throws -> SkipStateStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("skip_state.sqlite3")
        return try SkipStateStore(databasePath: path)
    }

    func testSkippedPathIsReturnedByQuery() async throws {
        let store = try makeStore()

        try await store.skip(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")

        let skipped = try await store.skippedAssetPaths(inFolder: "/card/DCIM/100")
        XCTAssertEqual(skipped, ["/card/DCIM/100/a.jpg"])
    }

    func testUnskipRemovesThePathFromTheSkippedSet() async throws {
        let store = try makeStore()
        try await store.skip(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")

        try await store.unskip(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")

        let skipped = try await store.skippedAssetPaths(inFolder: "/card/DCIM/100")
        XCTAssertTrue(skipped.isEmpty)
    }

    func testSkippingTheSamePathTwiceDoesNotDuplicateOrThrow() async throws {
        let store = try makeStore()

        try await store.skip(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")
        try await store.skip(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")

        let skipped = try await store.skippedAssetPaths(inFolder: "/card/DCIM/100")
        XCTAssertEqual(skipped, ["/card/DCIM/100/a.jpg"])
    }

    func testSkipStateIsScopedPerFolderNotGlobal() async throws {
        // Same filename skipped in one folder must not appear skipped when the same relative
        // path exists under a different folder.
        let store = try makeStore()
        try await store.skip(assetPaths: ["/card/DCIM/100/a.jpg"], inFolder: "/card/DCIM/100")

        let skippedElsewhere = try await store.skippedAssetPaths(inFolder: "/card/DCIM/200")
        XCTAssertTrue(skippedElsewhere.isEmpty)
    }

    func testSkippingMultiplePathsAtOnceMarksAllOfThem() async throws {
        // Mirrors skipping a whole capture set: every member path skipped in one call.
        let store = try makeStore()
        let paths = ["/card/DCIM/100/a.jpg", "/card/DCIM/100/a.orf"]

        try await store.skip(assetPaths: paths, inFolder: "/card/DCIM/100")

        let skipped = try await store.skippedAssetPaths(inFolder: "/card/DCIM/100")
        XCTAssertEqual(skipped, Set(paths))
    }
}
