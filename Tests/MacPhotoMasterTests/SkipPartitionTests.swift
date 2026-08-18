import XCTest

@testable import MacPhotoMasterCore

final class SkipPartitionTests: XCTestCase {
    private func asset(_ name: String) -> PhotoAsset {
        PhotoAsset(id: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func path(_ name: String) -> String { "/tmp/\(name)" }

    func testGroupWithNoSkippedMembersStaysWhollyActive() {
        let group = CaptureSet(members: [asset("A.jpg"), asset("A.orf")])

        let result = SkipPartition.split([group], skippedPaths: [])

        XCTAssertEqual(result.active.count, 1)
        XCTAssertEqual(result.active[0].members.count, 2)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testGroupWithEverySkippedMemberStaysWhollySkipped() {
        let group = CaptureSet(members: [asset("A.jpg"), asset("A.orf")])

        let result = SkipPartition.split(
            [group], skippedPaths: [path("A.jpg"), path("A.orf")])

        XCTAssertTrue(result.active.isEmpty)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped[0].members.count, 2)
    }

    /// The per-image skip this whole type exists for: one frame culled out of a bracket leaves the
    /// rest of the set on screen, rather than taking the set with it.
    func testPartiallySkippedGroupAppearsInBothHalves() {
        let group = CaptureSet(
            members: [asset("A.jpg"), asset("B.jpg"), asset("C.jpg")])

        let result = SkipPartition.split([group], skippedPaths: [path("B.jpg")])

        XCTAssertEqual(result.active.map { $0.members.map(\.url.lastPathComponent) }, [["A.jpg", "C.jpg"]])
        XCTAssertEqual(result.skipped.map { $0.members.map(\.url.lastPathComponent) }, [["B.jpg"]])
    }

    func testBothHalvesKeepTheGroupID() {
        let group = CaptureSet(members: [asset("A.jpg"), asset("B.jpg")])

        let result = SkipPartition.split([group], skippedPaths: [path("B.jpg")])

        XCTAssertEqual(result.active[0].id, group.id)
        XCTAssertEqual(result.skipped[0].id, group.id)
    }

    func testMemberOrderIsPreservedWithinEachHalf() {
        let group = CaptureSet(
            members: [asset("A.jpg"), asset("B.jpg"), asset("C.jpg"), asset("D.jpg")])

        let result = SkipPartition.split(
            [group], skippedPaths: [path("A.jpg"), path("C.jpg")])

        XCTAssertEqual(result.active[0].members.map(\.url.lastPathComponent), ["B.jpg", "D.jpg"])
        XCTAssertEqual(result.skipped[0].members.map(\.url.lastPathComponent), ["A.jpg", "C.jpg"])
    }

    func testGroupOrderIsPreservedAcrossHalves() {
        let first = CaptureSet(members: [asset("A.jpg")])
        let second = CaptureSet(members: [asset("B.jpg")])
        let third = CaptureSet(members: [asset("C.jpg")])

        let result = SkipPartition.split(
            [first, second, third], skippedPaths: [path("B.jpg")])

        XCTAssertEqual(result.active.map { $0.members[0].url.lastPathComponent }, ["A.jpg", "C.jpg"])
        XCTAssertEqual(result.skipped.map { $0.members[0].url.lastPathComponent }, ["B.jpg"])
    }

    /// A path recorded as skipped in a different folder (or for a file since deleted) must not
    /// silently drop a member that isn't in this folder's groups at all.
    func testUnrelatedSkippedPathsAreIgnored() {
        let group = CaptureSet(members: [asset("A.jpg")])

        let result = SkipPartition.split([group], skippedPaths: ["/elsewhere/Z.jpg"])

        XCTAssertEqual(result.active.count, 1)
        XCTAssertTrue(result.skipped.isEmpty)
    }
}
