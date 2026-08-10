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

    func testSoocTokenForARawDevelopedJPEGIsEmpty() {
        var derived = PhotoAsset(id: URL(fileURLWithPath: "/tmp/derived.jpg"))
        derived.derivedFrom = URL(fileURLWithPath: "/tmp/P1010042.ORF")

        XCTAssertEqual(AutoMetadataRules.soocToken(for: derived), "")
        // The camera's own JPEG alongside it still gets the token.
        XCTAssertEqual(AutoMetadataRules.soocToken(for: PhotoAsset(id: URL(fileURLWithPath: "/tmp/P1010042.JPG"))), "sooc")
    }

    // MARK: - cameraLookInstructions

    /// The look an ORF and its sibling JPEG both parse to. Measured on H1071885 (2026-08-09): the
    /// pair differs in `PictureMode` alone, so the ORF's readings are the JPEG's readings.
    private func colorCreatorLook(mode: String) -> CameraLook {
        var look = CameraLook()
        look.mode = mode
        look.colorCreator = CameraLook.ColorCreator(position: 0, name: "neutral", strength: -1)
        return look
    }

    func testCameraLookInstructionsForJPEGIsTheSummary() {
        var asset = PhotoAsset(id: URL(fileURLWithPath: "/tmp/H1071885.JPG"))
        asset.cameraLook = colorCreatorLook(mode: "Color Creator")

        XCTAssertEqual(AutoMetadataRules.cameraLookInstructions(for: asset), asset.cameraLookSummary)
        XCTAssertFalse(asset.cameraLookSummary.isEmpty)
    }

    func testCameraLookInstructionsForRAWIsEmpty() {
        var asset = PhotoAsset(id: URL(fileURLWithPath: "/tmp/H1071885.ORF"))
        asset.cameraLook = colorCreatorLook(mode: "Natural")

        // The readings parse, so the guard has to be the file type - not an empty look.
        XCTAssertFalse(asset.cameraLookSummary.isEmpty)
        XCTAssertEqual(AutoMetadataRules.cameraLookInstructions(for: asset), "")
    }

    func testCameraLookInstructionsForARawDevelopedJPEGIsEmpty() {
        var derived = PhotoAsset(id: URL(fileURLWithPath: "/tmp/derived.jpg"))
        derived.derivedFrom = URL(fileURLWithPath: "/tmp/H1071885.ORF")
        derived.cameraLook = colorCreatorLook(mode: "Natural")

        XCTAssertEqual(AutoMetadataRules.cameraLookInstructions(for: derived), "")
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
