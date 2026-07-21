import CoreGraphics
import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class AISuggestionServiceTests: XCTestCase {
    private func makeImage(width: Int = 40, height: Int = 20) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - parse

    func testParsePlainJSON() {
        let text = #"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#

        let result = AISuggestionService.parse(text)

        XCTAssertEqual(result?.description, "A red bird on a branch.")
        XCTAssertEqual(result?.keywords, ["red bird", "branch"])
    }

    func testParseJSONInCodeFence() {
        let text = """
            ```json
            {"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}
            ```
            """

        let result = AISuggestionService.parse(text)

        XCTAssertEqual(result?.description, "A red bird on a branch.")
        XCTAssertEqual(result?.keywords, ["red bird", "branch"])
    }

    func testParseJSONEmbeddedInProseFallsBackToRegex() {
        let text = """
            Sure! Here's what I see: {"description": "A red bird on a branch.", "keywords": ["red bird"]} \
            Let me know if you'd like changes.
            """

        let result = AISuggestionService.parse(text)

        XCTAssertEqual(result?.description, "A red bird on a branch.")
        XCTAssertEqual(result?.keywords, ["red bird"])
    }

    func testParseMissingDescriptionReturnsNil() {
        let text = #"{"keywords": ["red bird"]}"#

        XCTAssertNil(AISuggestionService.parse(text))
    }

    func testParseEmptyKeywordsReturnsNil() {
        let text = #"{"description": "A red bird on a branch.", "keywords": []}"#

        XCTAssertNil(AISuggestionService.parse(text))
    }

    // MARK: - buildUserPrompt / scene category

    func testBuildUserPromptForOtherCategoryUsesGenericWordLimitButStillIncludesSpeciesInstruction() {
        let prompt = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .other)

        XCTAssertTrue(prompt.contains("at most 30 words"))
        // Species-ID instructions are always sent (phrased conditionally) since Vision's triage
        // confidence isn't reliable enough to gate them on — see AISuggestionService's doc comment.
        XCTAssertTrue(prompt.contains("If the primary subject is a bird"))
        XCTAssertTrue(prompt.contains("Latin binomial"))
        XCTAssertTrue(prompt.contains("never invent one"))
    }

    func testBuildUserPromptForBirdCategoryUsesHigherWordLimit() {
        let prompt = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .bird)

        XCTAssertTrue(prompt.contains("at most 60 words"))
        XCTAssertTrue(prompt.contains("If the primary subject is a bird"))
        XCTAssertTrue(prompt.contains("Latin binomial"))
        XCTAssertTrue(prompt.contains("never invent one"))
    }

    func testBuildUserPromptForFlowerCategoryUsesHigherWordLimit() {
        let prompt = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .flower)

        XCTAssertTrue(prompt.contains("at most 60 words"))
        XCTAssertTrue(prompt.contains("If the primary subject is a flower or flowering plant"))
        XCTAssertTrue(prompt.contains("Latin binomial"))
        XCTAssertTrue(prompt.contains("never invent one"))
    }

    // MARK: - buildUserPrompt / compact profile (small on-device models)

    func testCompactPromptOmitsCopyableKeywordPlaceholder() {
        // The whole reason the compact profile exists: small models echo the full prompt's
        // ["k1","k2"] JSON example verbatim, so the compact variant must never contain it.
        let full = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .other,
            promptProfile: .full)
        let compact = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .other,
            promptProfile: .compact)

        XCTAssertTrue(full.contains("\"k1\""), "guards against the full prompt quietly changing")
        XCTAssertFalse(compact.contains("k1"))
        XCTAssertFalse(compact.contains("k2"))
        XCTAssertTrue(compact.contains("array of lowercase strings"))
    }

    func testCompactPromptGatesSpeciesInstructionsOnCategory() {
        // Unlike the full prompt (always-on species-ID), the compact prompt only asks for species ID
        // when triage classified the subject — this is the fix for bird-ID'ing non-wildlife subjects.
        let other = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .other,
            promptProfile: .compact)
        XCTAssertFalse(other.contains("bird"))
        XCTAssertFalse(other.contains("Latin binomial"))

        let bird = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .bird,
            promptProfile: .compact)
        XCTAssertTrue(bird.contains("Name the bird's species"))
        XCTAssertTrue(bird.contains("Latin binomial"))
        // Imperative, not a declarative the model can echo as the description.
        XCTAssertFalse(bird.contains("This is a bird"))

        let flower = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .flower,
            promptProfile: .compact)
        XCTAssertTrue(flower.contains("Name the plant's species"))
        XCTAssertFalse(flower.contains("Name the bird's species"))
    }

    func testCompactPromptGatesLocationSpeciesPreferenceOnCategory() {
        // The "prefer a locally-recorded species" line is bird/flower-specific, so on a non-wildlife
        // subject it must not appear even when location context is present.
        let other = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "city=Point Reyes",
            category: .other, promptProfile: .compact)
        XCTAssertTrue(other.contains("Location context"))
        XCTAssertFalse(other.contains("prefer a species"))

        let bird = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "city=Point Reyes",
            category: .bird, promptProfile: .compact)
        XCTAssertTrue(bird.contains("prefer a species"))
    }

    func testCommonNamesOnlyFlagChangesBirdCandidateInstruction() {
        let full = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .bird,
            birdCandidateSpecies: "Great Blue Heron", promptProfile: .full,
            birdCandidatesAreCommonNamesOnly: false)
        XCTAssertTrue(full.contains("exact common and scientific name"))

        let commonOnly = AISuggestionService.buildUserPrompt(
            existingDescription: "", existingKeywords: "", locationContext: "", category: .bird,
            birdCandidateSpecies: "Great Blue Heron", promptProfile: .full,
            birdCandidatesAreCommonNamesOnly: true)
        XCTAssertFalse(commonOnly.contains("exact common and scientific name"))
        XCTAssertTrue(commonOnly.contains("do not write a scientific name"))
        XCTAssertTrue(commonOnly.contains("Great Blue Heron"))
    }

    // MARK: - suggest / fallback

    func testSuggestReturnsPrimaryResultWithoutRetryFlags() async throws {
        let provider = FakeAIProvider()
        provider.chatResponses = [
            .success(#"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#)
        ]
        let service = AISuggestionService()

        let result = try await service.suggest(
            provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
            existingKeywords: "")

        XCTAssertEqual(result.description, "A red bird on a branch.")
        XCTAssertFalse(result.timeoutRetryAttempted)
        XCTAssertFalse(result.timeoutRetrySucceeded)
        XCTAssertEqual(provider.thinkValuesPerCall, [true])
    }

    func testSuggestRetriesOnceOnTimeoutThenSucceeds() async throws {
        let provider = FakeAIProvider()
        provider.chatResponses = [
            .failure(AISuggestionError.timeout),
            .success(#"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#),
        ]
        let service = AISuggestionService()

        let result = try await service.suggest(
            provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
            existingKeywords: "")

        XCTAssertTrue(result.timeoutRetryAttempted)
        XCTAssertTrue(result.timeoutRetrySucceeded)
        XCTAssertEqual(provider.thinkValuesPerCall, [true, false])
    }

    func testSuggestPropagatesNonRetryableProviderErrorWithoutRetrying() async {
        let provider = FakeAIProvider()
        provider.chatResponses = [.failure(AISuggestionError.provider("boom"))]
        let service = AISuggestionService()

        do {
            _ = try await service.suggest(
                provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
                existingKeywords: "")
            XCTFail("Expected suggest to throw")
        } catch {
            XCTAssertEqual(provider.thinkValuesPerCall, [true])
        }
    }

    func testSuggestIncludesExistingKeywordsAsStrongGuideInPromptWhenProvided() async throws {
        let provider = FakeAIProvider()
        provider.chatResponses = [
            .success(#"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#)
        ]
        let service = AISuggestionService()

        _ = try await service.suggest(
            provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
            existingKeywords: "northern cardinal, cardinalis cardinalis")

        let prompt = try XCTUnwrap(provider.userPromptsPerCall.first)
        XCTAssertTrue(prompt.contains("strong, trusted guide"))
        XCTAssertTrue(prompt.contains("northern cardinal, cardinalis cardinalis"))
    }

    func testSuggestOmitsExistingKeywordsLineWhenBlank() async throws {
        let provider = FakeAIProvider()
        provider.chatResponses = [
            .success(#"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#)
        ]
        let service = AISuggestionService()

        _ = try await service.suggest(
            provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
            existingKeywords: "")

        let prompt = try XCTUnwrap(provider.userPromptsPerCall.first)
        XCTAssertFalse(prompt.contains("strong, trusted guide"))
    }

    func testSuggestIncludesLocationContextInPromptWhenProvided() async throws {
        let provider = FakeAIProvider()
        provider.chatResponses = [
            .success(#"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#)
        ]
        let service = AISuggestionService()

        _ = try await service.suggest(
            provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
            existingKeywords: "", locationContext: "city=Portland; state=Oregon")

        let prompt = try XCTUnwrap(provider.userPromptsPerCall.first)
        XCTAssertTrue(prompt.contains("city=Portland; state=Oregon"))
    }

    func testSuggestOmitsLocationContextLineWhenBlank() async throws {
        let provider = FakeAIProvider()
        provider.chatResponses = [
            .success(#"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#)
        ]
        let service = AISuggestionService()

        _ = try await service.suggest(
            provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
            existingKeywords: "")

        let prompt = try XCTUnwrap(provider.userPromptsPerCall.first)
        XCTAssertFalse(prompt.contains("Location context"))
    }

    func testSuggestIncludesBirdCandidateSpeciesInPromptWhenProvided() async throws {
        let provider = FakeAIProvider()
        provider.chatResponses = [
            .success(#"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#)
        ]
        let service = AISuggestionService()

        _ = try await service.suggest(
            provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
            existingKeywords: "",
            birdCandidateSpecies: "Common Raven (Corvus corax), House Finch (Haemorhous mexicanus)")

        let prompt = try XCTUnwrap(provider.userPromptsPerCall.first)
        XCTAssertTrue(prompt.contains("Common Raven (Corvus corax), House Finch (Haemorhous mexicanus)"))
    }

    func testSuggestOmitsBirdCandidateSpeciesLineWhenBlank() async throws {
        let provider = FakeAIProvider()
        provider.chatResponses = [
            .success(#"{"description": "A red bird on a branch.", "keywords": ["red bird", "branch"]}"#)
        ]
        let service = AISuggestionService()

        _ = try await service.suggest(
            provider: provider, model: "qwen3.6:35b", image: makeImage(), existingDescription: "",
            existingKeywords: "")

        let prompt = try XCTUnwrap(provider.userPromptsPerCall.first)
        XCTAssertFalse(prompt.contains("verified as ever recorded"))
    }

    func testSuggestPropagatesVisionCheckFailureWithoutSendingChat() async {
        let provider = FakeAIProvider()
        provider.visionCheckError = AISuggestionError.provider("not vision-capable")
        let service = AISuggestionService()

        do {
            _ = try await service.suggest(
                provider: provider, model: "llama3.2:1b", image: makeImage(), existingDescription: "",
                existingKeywords: "")
            XCTFail("Expected suggest to throw")
        } catch {
            XCTAssertTrue(provider.thinkValuesPerCall.isEmpty)
        }
    }
}

private final class FakeAIProvider: AIProvider {
    var visionCheckError: Error?
    var chatResponses: [Result<String, Error>] = []
    private(set) var thinkValuesPerCall: [Bool] = []
    private(set) var userPromptsPerCall: [String] = []

    func ensureVisionCapable(model: String) async throws {
        if let visionCheckError { throw visionCheckError }
    }

    func chat(
        model: String, systemPrompt: String, userPrompt: String, imagePayloads: [String], think: Bool
    ) async throws -> String {
        let callIndex = thinkValuesPerCall.count
        thinkValuesPerCall.append(think)
        userPromptsPerCall.append(userPrompt)
        guard callIndex < chatResponses.count else {
            throw AISuggestionError.provider("no more fake responses")
        }
        switch chatResponses[callIndex] {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}
