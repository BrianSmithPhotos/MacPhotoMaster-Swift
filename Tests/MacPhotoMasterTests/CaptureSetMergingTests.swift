import XCTest

@testable import MacPhotoMasterCore

final class CaptureSetMergingTests: XCTestCase {
    private func set(_ names: String...) -> CaptureSet {
        CaptureSet(members: names.map { PhotoAsset(id: URL(fileURLWithPath: "/tmp/\($0)")) })
    }

    private func names(_ sets: [CaptureSet]) -> [[String]] {
        sets.map { $0.members.map { $0.url.lastPathComponent } }
    }

    private func path(_ name: String) -> String { "/tmp/\(name)" }

    func testGroupsAreUntouchedWhenNothingIsMerged() {
        let groups = [set("A.jpg"), set("B.jpg")]

        let merged = CaptureSetMerging.apply(groups, mergeIDsByAssetPath: [:])

        XCTAssertEqual(names(merged), [["A.jpg"], ["B.jpg"]])
    }

    func testSetsSharingAMergeIDBecomeOne() {
        let groups = [set("A.jpg"), set("B.jpg"), set("C.jpg")]
        let ids = [path("A.jpg"): "m1", path("B.jpg"): "m1", path("C.jpg"): "m1"]

        let merged = CaptureSetMerging.apply(groups, mergeIDsByAssetPath: ids)

        XCTAssertEqual(names(merged), [["A.jpg", "B.jpg", "C.jpg"]])
    }

    /// The merged set has to land where its first frame was, or merging would reorder the browser.
    func testAMergedSetKeepsThePositionAndIDOfItsEarliestConstituent() {
        let groups = [set("A.jpg"), set("B.jpg"), set("C.jpg")]
        let ids = [path("A.jpg"): "m1", path("C.jpg"): "m1"]

        let merged = CaptureSetMerging.apply(groups, mergeIDsByAssetPath: ids)

        XCTAssertEqual(names(merged), [["A.jpg", "C.jpg"], ["B.jpg"]])
        XCTAssertEqual(merged.first?.id, groups.first?.id)
    }

    func testTwoSeparateMergesStaySeparate() {
        let groups = [set("A.jpg"), set("B.jpg"), set("C.jpg"), set("D.jpg")]
        let ids = [
            path("A.jpg"): "m1", path("B.jpg"): "m2", path("C.jpg"): "m1", path("D.jpg"): "m2",
        ]

        let merged = CaptureSetMerging.apply(groups, mergeIDsByAssetPath: ids)

        XCTAssertEqual(names(merged), [["A.jpg", "C.jpg"], ["B.jpg", "D.jpg"]])
    }

    /// Merging records the paths that existed at the time. A frame that joins one of those sets
    /// afterwards — a developed RAW landing in its original's group — arrives inside an
    /// already-merged group and must come along without a row of its own.
    func testAMemberAddedAfterTheMergeComesAlongWithItsGroup() {
        let groups = [set("A.orf", "developed_A.jpg"), set("B.jpg")]
        let ids = [path("A.orf"): "m1", path("B.jpg"): "m1"]

        let merged = CaptureSetMerging.apply(groups, mergeIDsByAssetPath: ids)

        XCTAssertEqual(names(merged), [["A.orf", "developed_A.jpg", "B.jpg"]])
    }

    /// Recorded paths for files no longer in the folder (a card reshoot, a moved file) must not
    /// resurrect anything or drop the sets that are still there.
    func testStaleRecordedPathsAreIgnored() {
        let groups = [set("A.jpg")]
        let ids = [path("A.jpg"): "m1", path("gone.jpg"): "m1"]

        let merged = CaptureSetMerging.apply(groups, mergeIDsByAssetPath: ids)

        XCTAssertEqual(names(merged), [["A.jpg"]])
    }
}
