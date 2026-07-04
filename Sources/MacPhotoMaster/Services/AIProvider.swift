import Foundation

/// Normalized failure modes an `AIProvider` implementation must map its own errors onto, so
/// `AISuggestionService`'s fallback chain (docs/SPEC.md §6) can react the same way regardless of
/// backend. `.timeout` and `.emptyResponse` are the two cases the fallback retries once; `.provider`
/// covers everything else (network failure, non-vision model, HTTP error) and is surfaced directly.
enum AISuggestionError: Error, LocalizedError, Equatable {
    case timeout
    case emptyResponse
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "AI request timed out"
        case .emptyResponse: return "AI returned an empty response"
        case .provider(let message): return message
        }
    }
}

/// A backend that can answer one vision-capable chat request — the seam docs/SPEC.md §6 asks for so
/// adding a second backend (e.g. an OpenRouter cloud provider) means writing one new conformance,
/// not touching `AISuggestionService`'s prompting/parsing/fallback logic. `OllamaProvider` is the
/// first (and, for now, only) implementation.
protocol AIProvider {
    /// Throws `.provider(...)` if `model` isn't available or isn't vision-capable. Called before
    /// every request, per spec's "vision-capability pre-check before sending an image request."
    func ensureVisionCapable(model: String) async throws

    /// Sends one chat request with `imagePayloads` (base64-encoded image data) attached to the user
    /// message, returning the raw text response. `think: false` requests a lower-effort/faster
    /// response — used only by the fallback retry (docs/SPEC.md §6).
    func chat(
        model: String, systemPrompt: String, userPrompt: String, imagePayloads: [String], think: Bool
    ) async throws -> String
}
