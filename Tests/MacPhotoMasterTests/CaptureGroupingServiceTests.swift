import XCTest

@testable import MacPhotoMaster

final class CaptureGroupingServiceTests: XCTestCase {
    private let service = CaptureGroupingService()

    private func asset(_ name: String, capturedAt: Date?) -> PhotoAsset {
        var asset = PhotoAsset(id: URL(fileURLWithPath: "/tmp/\(name)"))
        asset.capturedAt = capturedAt
        return asset
    }

    func testAssetsWithinSameSecondAreGroupedTogether() {
        let base = Date(timeIntervalSince1970: 1_000)
        let jpeg = asset("A.jpg", capturedAt: base)
        let raw = asset("A.orf", capturedAt: base.addingTimeInterval(0.4))

        let sets = service.group([jpeg, raw])

        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(Set(sets[0].members.map(\.id)), Set([jpeg.id, raw.id]))
    }

    func testAssetsOneSecondApartAreSeparateSets() {
        let base = Date(timeIntervalSince1970: 1_000)
        let first = asset("A.jpg", capturedAt: base)
        let second = asset("B.jpg", capturedAt: base.addingTimeInterval(1))

        let sets = service.group([first, second])

        XCTAssertEqual(sets.count, 2)
    }

    func testAssetsWithoutCaptureTimeEachBecomeTheirOwnSet() {
        let noTimestampA = asset("A.jpg", capturedAt: nil)
        let noTimestampB = asset("B.jpg", capturedAt: nil)

        let sets = service.group([noTimestampA, noTimestampB])

        XCTAssertEqual(sets.count, 2)
    }

    func testSetsAreOrderedChronologicallyRegardlessOfInputOrder() {
        let base = Date(timeIntervalSince1970: 1_000)
        let later = asset("B.jpg", capturedAt: base.addingTimeInterval(5))
        let earlier = asset("A.jpg", capturedAt: base)

        let sets = service.group([later, earlier])

        XCTAssertEqual(sets.first?.members.first?.id, earlier.id)
        XCTAssertEqual(sets.last?.members.first?.id, later.id)
    }

    func testUntimedSetsSortAfterAllTimedSets() {
        let base = Date(timeIntervalSince1970: 1_000)
        let timed = asset("A.jpg", capturedAt: base)
        let untimed = asset("B.jpg", capturedAt: nil)

        let sets = service.group([untimed, timed])

        XCTAssertEqual(sets.last?.members.first?.id, untimed.id)
    }
}
