import XCTest

@testable import MacPhotoMaster

final class AIModelSelectionTests: XCTestCase {
    func testParsesOllamaModelWithColonInModelTag() {
        let selection = AIModelSelection.parse("ollama:qwen2.5vl:72b")
        XCTAssertEqual(selection?.providerID, .ollama)
        XCTAssertEqual(selection?.modelName, "qwen2.5vl:72b")
    }

    func testParsesOpenRouterModelWithSlashInSlug() {
        let selection = AIModelSelection.parse("openrouter:google/gemini-2.5-flash")
        XCTAssertEqual(selection?.providerID, .openRouter)
        XCTAssertEqual(selection?.modelName, "google/gemini-2.5-flash")
    }

    func testTrimsWhitespace() {
        let selection = AIModelSelection.parse("  ollama:qwen3.6:35b  ")
        XCTAssertEqual(selection?.providerID, .ollama)
        XCTAssertEqual(selection?.modelName, "qwen3.6:35b")
    }

    func testReturnsNilForUnknownProviderPrefix() {
        XCTAssertNil(AIModelSelection.parse("bogus:some-model"))
    }

    func testReturnsNilWhenNoColonPresent() {
        XCTAssertNil(AIModelSelection.parse("qwen3.6:35b".replacingOccurrences(of: ":", with: "")))
    }

    func testReturnsNilForEmptyModelName() {
        XCTAssertNil(AIModelSelection.parse("ollama:"))
    }

    func testAllPresetsParseSuccessfully() {
        for preset in AIModelSelection.presets {
            XCTAssertNotNil(AIModelSelection.parse(preset), "failed to parse preset: \(preset)")
        }
    }

    func testFirstPresetIsDefaultAIModelText() {
        XCTAssertEqual(AIModelSelection.presets.first, "ollama:qwen3.6:35b")
    }
}
