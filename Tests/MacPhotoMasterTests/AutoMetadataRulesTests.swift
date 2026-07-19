import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class AutoMetadataRulesTests: XCTestCase {
    // MARK: - soocToken

    func testSoocTokenForJPEGIsSooc() {
        XCTAssertEqual(AutoMetadataRules.soocToken(for: URL(fileURLWithPath: "/tmp/P1010042.JPG")), "sooc")
        XCTAssertEqual(AutoMetadataRules.soocToken(for: URL(fileURLWithPath: "/tmp/P1010042.jpeg")), "sooc")
    }

    func testSoocTokenForRAWIsEmpty() {
        XCTAssertEqual(AutoMetadataRules.soocToken(for: URL(fileURLWithPath: "/tmp/P1010042.ORF")), "")
    }

    // MARK: - keywordsWithAutoTokens

    func testKeywordsWithAutoTokensAppendsAllProvidedTokens() {
        let keywords = AutoMetadataRules.keywordsWithAutoTokens(
            ["sunset", "beach"], artFilterToken: "Grainy Film II", cameraToken: "OM-1", lensToken: "12-40mm",
            soocToken: "sooc")

        XCTAssertEqual(keywords, ["sunset", "beach", "Grainy Film II", "OM-1", "12-40mm", "sooc"])
    }

    func testKeywordsWithAutoTokensSkipsBlankTokens() {
        let keywords = AutoMetadataRules.keywordsWithAutoTokens(
            ["sunset"], artFilterToken: nil, cameraToken: "", lensToken: "  ", soocToken: "")

        XCTAssertEqual(keywords, ["sunset"])
    }

    func testKeywordsWithAutoTokensDeduplicatesCaseInsensitively() {
        let keywords = AutoMetadataRules.keywordsWithAutoTokens(
            ["OM-1", "sooc"], artFilterToken: nil, cameraToken: "om-1", lensToken: nil, soocToken: "SOOC")

        XCTAssertEqual(keywords, ["OM-1", "sooc"])
    }

    // MARK: - descriptionWithArtFilterNote

    func testDescriptionWithArtFilterNoteAppendsNote() {
        let description = AutoMetadataRules.descriptionWithArtFilterNote(
            "A misty morning.", artFilterToken: "Grainy Film II")

        XCTAssertEqual(description, "A misty morning. In camera effect Grainy Film II.")
    }

    func testDescriptionWithArtFilterNoteHandlesEmptyDescription() {
        let description = AutoMetadataRules.descriptionWithArtFilterNote("", artFilterToken: "Grainy Film II")

        XCTAssertEqual(description, "In camera effect Grainy Film II.")
    }

    func testDescriptionWithArtFilterNoteNoTokenReturnsUnchanged() {
        let description = AutoMetadataRules.descriptionWithArtFilterNote("A misty morning.", artFilterToken: nil)

        XCTAssertEqual(description, "A misty morning.")
    }

    func testDescriptionWithArtFilterNoteDoesNotDuplicateExistingNote() {
        let original = "A misty morning. In camera effect Grainy Film II."
        let description = AutoMetadataRules.descriptionWithArtFilterNote(
            original, artFilterToken: "Grainy Film II")

        XCTAssertEqual(description, original)
    }
}
