import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class BatchAISuggestionTargetsTests: XCTestCase {
    /// A set of one file, described or not — enough for a rule that only reads description text.
    private func set(_ name: String, description: String = "") -> CaptureSet {
        var asset = PhotoAsset(id: URL(fileURLWithPath: "/card/\(name)"))
        asset.descriptionText = description
        return CaptureSet(members: [asset])
    }

    private func representativeIDs(of sets: [CaptureSet]) -> Set<PhotoAsset.ID> {
        Set(sets.compactMap { $0.representative?.id })
    }

    private func names(_ sets: [CaptureSet]) -> [String] {
        sets.compactMap { $0.representative?.url.lastPathComponent }
    }

    func testWholeFolderWhenNothingIsSelected() {
        let folder = [set("A.JPG"), set("B.JPG"), set("C.JPG")]

        let targets = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: [], redescribingDescribed: false)

        XCTAssertEqual(names(targets), ["A.JPG", "B.JPG", "C.JPG"])
    }

    func testSelectionWinsOverTheFolderAndKeepsGridOrder() {
        let folder = [set("A.JPG"), set("B.JPG"), set("C.JPG")]
        let selected = representativeIDs(of: [folder[2], folder[0]])

        let targets = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: selected, redescribingDescribed: false)

        XCTAssertEqual(names(targets), ["A.JPG", "C.JPG"])
    }

    func testAlreadyDescribedSetsAreLeftAlone() {
        let folder = [set("A.JPG", description: "Written by hand"), set("B.JPG")]

        let targets = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: [], redescribingDescribed: false)

        XCTAssertEqual(names(targets), ["B.JPG"])
    }

    /// One selected tile is the cursor, not a selection: the grid puts the clicked set's id in
    /// `multiSelectedIDs` on every plain click, so honouring it here would mean a batch run silently
    /// covering one set instead of the folder — with the button still saying "all".
    func testASingleSelectedSetIsIgnoredAndTheFolderRunsInstead() {
        let folder = [set("A.JPG"), set("B.JPG"), set("C.JPG")]
        let cursor = representativeIDs(of: [folder[1]])

        let targets = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: cursor, redescribingDescribed: false)

        XCTAssertEqual(names(targets), ["A.JPG", "B.JPG", "C.JPG"])
    }

    /// The skip rule applies to a selection too: picking sets and pressing the button is not the
    /// same as asking for prose to be overwritten, which `redescribingDescribed` is for.
    func testSelectionStillSkipsDescribedSetsUnlessAsked() {
        let folder = [set("A.JPG", description: "Written by hand"), set("B.JPG")]
        let selected = representativeIDs(of: folder)

        let kept = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: selected, redescribingDescribed: false)
        let redone = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: selected, redescribingDescribed: true)

        XCTAssertEqual(names(kept), ["B.JPG"])
        XCTAssertEqual(names(redone), ["A.JPG", "B.JPG"])
    }

    /// Whitespace is not a description. A field that only ever held a space would otherwise exempt
    /// its set from every batch run the user ever makes, with nothing on screen to explain why.
    func testWhitespaceOnlyDescriptionDoesNotCountAsDescribed() {
        let folder = [set("A.JPG", description: "   \n ")]

        let targets = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: [], redescribingDescribed: false)

        XCTAssertEqual(names(targets), ["A.JPG"])
    }

    /// A RAW+JPEG set where only the RAW carries prose is still a set someone has worked on: a save
    /// writes every member, so description on any member means the set has been described.
    func testDescriptionOnANonRepresentativeMemberCounts() {
        var raw = PhotoAsset(id: URL(fileURLWithPath: "/card/A.ORF"))
        raw.descriptionText = "Written by hand"
        let jpeg = PhotoAsset(id: URL(fileURLWithPath: "/card/A.JPG"))
        let folder = [CaptureSet(members: [jpeg, raw])]

        let targets = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: [], redescribingDescribed: false)

        XCTAssertTrue(targets.isEmpty)
    }

    func testNothingToDoWhenEveryCandidateIsDescribed() {
        let folder = [set("A.JPG", description: "One"), set("B.JPG", description: "Two")]

        let targets = BatchAISuggestionTargets.sets(
            in: folder, multiSelectedRepresentativeIDs: [], redescribingDescribed: false)

        XCTAssertTrue(targets.isEmpty)
    }
}
