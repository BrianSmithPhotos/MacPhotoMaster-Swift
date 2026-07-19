import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class ProcessMoveScopeTests: XCTestCase {
    private func makeAsset(_ name: String) -> PhotoAsset {
        PhotoAsset(id: URL(fileURLWithPath: "/card/\(name)"))
    }

    func testSingleAssetScopeResolvesToJustThatAsset() {
        let asset = makeAsset("P1010042.JPG")

        XCTAssertEqual(ProcessMoveScope.singleAsset(asset).assets, [asset])
    }

    func testCaptureSetScopeResolvesToAllMembers() {
        let members = [makeAsset("P1010042.JPG"), makeAsset("P1010042.ORF")]
        let captureSet = CaptureSet(members: members)

        XCTAssertEqual(ProcessMoveScope.captureSet(captureSet).assets, members)
    }

    func testSessionScopeResolvesToAllMembersOfEveryCaptureSetInOrder() {
        let firstSet = CaptureSet(members: [makeAsset("P1010042.JPG")])
        let secondSet = CaptureSet(members: [makeAsset("P1010099.JPG"), makeAsset("P1010099.ORF")])

        let assets = ProcessMoveScope.session([firstSet, secondSet]).assets

        XCTAssertEqual(assets, firstSet.members + secondSet.members)
    }
}
