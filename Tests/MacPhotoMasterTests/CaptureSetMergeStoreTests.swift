import XCTest

@testable import MacPhotoMasterCore

final class CaptureSetMergeStoreTests: XCTestCase {
    private let folder = "/card/DCIM/100"

    private func makeStore() throws -> CaptureSetMergeStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("capture_set_merges.sqlite3")
        return try CaptureSetMergeStore(databasePath: path)
    }

    func testMergedPathsComeBackUnderOneMergeID() async throws {
        let store = try makeStore()
        let paths = ["\(folder)/a.jpg", "\(folder)/b.jpg"]

        let mergeID = try await store.merge(assetPaths: paths, inFolder: folder)

        let stored = try await store.mergeIDsByAssetPath(inFolder: folder)
        XCTAssertEqual(stored, [paths[0]: mergeID, paths[1]: mergeID])
    }

    func testTwoMergesGetDifferentIDs() async throws {
        let store = try makeStore()

        let first = try await store.merge(assetPaths: ["\(folder)/a.jpg"], inFolder: folder)
        let second = try await store.merge(assetPaths: ["\(folder)/b.jpg"], inFolder: folder)

        XCTAssertNotEqual(first, second)
    }

    /// Merging a selection that already contains a merged set has to absorb it rather than leave the
    /// old id behind, or the result would come back as two sets.
    func testRemergingAPathMovesItIntoTheNewMerge() async throws {
        let store = try makeStore()
        let paths = ["\(folder)/a.jpg", "\(folder)/b.jpg"]
        _ = try await store.merge(assetPaths: [paths[0]], inFolder: folder)

        let mergeID = try await store.merge(assetPaths: paths, inFolder: folder)

        let stored = try await store.mergeIDsByAssetPath(inFolder: folder)
        XCTAssertEqual(Set(stored.values), [mergeID])
    }

    func testUnmergeClearsThePaths() async throws {
        let store = try makeStore()
        let paths = ["\(folder)/a.jpg", "\(folder)/b.jpg"]
        _ = try await store.merge(assetPaths: paths, inFolder: folder)

        try await store.unmerge(assetPaths: paths, inFolder: folder)

        let stored = try await store.mergeIDsByAssetPath(inFolder: folder)
        XCTAssertTrue(stored.isEmpty)
    }

    func testMergesAreScopedPerFolder() async throws {
        let store = try makeStore()
        _ = try await store.merge(assetPaths: ["\(folder)/a.jpg"], inFolder: folder)

        let elsewhere = try await store.mergeIDsByAssetPath(inFolder: "/card/DCIM/200")
        XCTAssertTrue(elsewhere.isEmpty)
    }
}
