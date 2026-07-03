import XCTest

@testable import MacPhotoMaster

final class SelectionScopeTests: XCTestCase {
    private func path(_ name: String) -> URL {
        URL(fileURLWithPath: "/card/\(name)")
    }

    // MARK: - expandToCaptureGroups

    func testExpandToCaptureGroupsPullsInUnselectedSiblings() {
        let a1 = path("a1.JPG"), a1raw = path("a1.ORF")
        let b1 = path("b1.JPG"), b1raw = path("b1.ORF"), b2 = path("b2.JPG")
        let membersByID: [URL: [URL]] = [
            a1: [a1, a1raw], a1raw: [a1, a1raw],
            b1: [b1, b1raw, b2], b1raw: [b1, b1raw, b2], b2: [b1, b1raw, b2],
        ]

        let expanded = SelectionScope.expandToCaptureGroups([a1, b1], membersByID: membersByID)

        XCTAssertEqual(Set(expanded), [a1, a1raw, b1, b1raw, b2])
    }

    func testExpandToCaptureGroupsPathWithNoGroupExpandsToItself() {
        let standalone = path("standalone.JPG")

        let expanded = SelectionScope.expandToCaptureGroups([standalone], membersByID: [:])

        XCTAssertEqual(expanded, [standalone])
    }

    func testExpandToCaptureGroupsDedupesAndPreservesFirstSeenOrder() {
        let a1 = path("a1.JPG"), a1raw = path("a1.ORF")
        let membersByID: [URL: [URL]] = [a1: [a1, a1raw], a1raw: [a1, a1raw]]

        let expanded = SelectionScope.expandToCaptureGroups([a1, a1raw], membersByID: membersByID)

        XCTAssertEqual(expanded, [a1, a1raw])
    }

    // MARK: - resolveScope

    func testResolveScopeSingleSelectionReturnsCurrentGroupOnly() {
        let a1 = path("a1.JPG"), a1raw = path("a1.ORF")
        let b1 = path("b1.JPG"), b1raw = path("b1.ORF")
        let membersByID: [URL: [URL]] = [
            a1: [a1, a1raw], a1raw: [a1, a1raw],
            b1: [b1, b1raw], b1raw: [b1, b1raw],
        ]

        let scope = SelectionScope.resolveScope(selected: a1, multiSelected: [a1], membersByID: membersByID)

        XCTAssertEqual(Set(scope), [a1, a1raw])
    }

    func testResolveScopeSinglePathNoGroupReturnsOnlyThatPath() {
        let standalone = path("standalone.JPG")

        let scope = SelectionScope.resolveScope(selected: standalone, multiSelected: [standalone], membersByID: [:])

        XCTAssertEqual(scope, [standalone])
    }

    func testResolveScopeMultiSelectionExpandsAllSelectedGroups() {
        let a1 = path("a1.JPG"), a1raw = path("a1.ORF")
        let b1 = path("b1.JPG"), b1raw = path("b1.ORF")
        let membersByID: [URL: [URL]] = [
            a1: [a1, a1raw], a1raw: [a1, a1raw],
            b1: [b1, b1raw], b1raw: [b1, b1raw],
        ]

        let scope = SelectionScope.resolveScope(
            selected: a1, multiSelected: [a1, b1], membersByID: membersByID)

        XCTAssertEqual(Set(scope), [a1, a1raw, b1, b1raw])
    }

    func testResolveScopeMultiSelectionDoesNotIncludeUnselectedGroup() {
        let a1 = path("a1.JPG"), a1raw = path("a1.ORF")
        let b1 = path("b1.JPG"), b1raw = path("b1.ORF")
        let c1 = path("c1.JPG"), c1raw = path("c1.ORF")
        let membersByID: [URL: [URL]] = [
            a1: [a1, a1raw], a1raw: [a1, a1raw],
            b1: [b1, b1raw], b1raw: [b1, b1raw],
            c1: [c1, c1raw], c1raw: [c1, c1raw],
        ]

        let scope = SelectionScope.resolveScope(
            selected: a1, multiSelected: [a1, b1], membersByID: membersByID)

        XCTAssertFalse(scope.contains(c1))
        XCTAssertFalse(scope.contains(c1raw))
    }

    // MARK: - rangeBetween

    func testRangeBetweenSelectsContiguousSpanRegardlessOfClickOrder() {
        let visible = [path("a.JPG"), path("b.JPG"), path("c.JPG"), path("d.JPG")]

        let forward = SelectionScope.rangeBetween(anchor: visible[1], target: visible[3], visible: visible)
        let backward = SelectionScope.rangeBetween(anchor: visible[3], target: visible[1], visible: visible)

        XCTAssertEqual(forward, [visible[1], visible[2], visible[3]])
        XCTAssertEqual(backward, [visible[1], visible[2], visible[3]])
    }

    func testRangeBetweenFallsBackToSinglePathWhenAnchorIsNotVisible() {
        let visible = [path("a.JPG"), path("b.JPG")]
        let staleAnchor = path("removed.JPG")

        XCTAssertEqual(
            SelectionScope.rangeBetween(anchor: staleAnchor, target: visible[1], visible: visible), [visible[1]])
    }

    func testRangeBetweenFallsBackToSinglePathWhenTargetIsNotVisible() {
        let visible = [path("a.JPG"), path("b.JPG")]
        let hiddenTarget = path("hidden.ORF")

        XCTAssertEqual(
            SelectionScope.rangeBetween(anchor: visible[0], target: hiddenTarget, visible: visible), [hiddenTarget])
    }
}
