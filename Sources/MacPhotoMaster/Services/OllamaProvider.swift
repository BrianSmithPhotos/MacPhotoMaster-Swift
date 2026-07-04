import Foundation
import os

/// Local Ollama backend for `AIProvider` — docs/SPEC.md §6's first AI provider. `URLSession`-based;
/// the first network client in this codebase. Ported from the Python reference app's
/// `services/ollama_provider.py`: same endpoints, same default model/timeout, same
/// dynamic-capability vision pre-check via `/api/tags` rather than a hardcoded model-name list.
struct OllamaProvider: AIProvider {
    /// Matches the Python reference app's own default (`OLLAMA_DEFAULT_MODEL`) — confirmed already
    /// pulled locally via `ollama list`.
    static let defaultModel = "qwen3.6:35b"

    private static let chatURL = URL(string: "http://127.0.0.1:11434/api/chat")!
    private static let tagsURL = URL(string: "http://127.0.0.1:11434/api/tags")!
    /// Matches the Python reference app's `OLLAMA_TIMEOUT_SECONDS` default — local vision models on
    /// this hardware can take a while, especially a first cold-start request.
    private static let timeoutSeconds: TimeInterval = 180
    private static let keepAlive = "15m"
    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "AISuggestion")

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Throws `.provider(...)` if `model` is blank, isn't pulled, or doesn't advertise `"vision"` in
    /// its capabilities — matches the Python reference app's dynamic `/api/tags` capability check
    /// rather than a hardcoded list of known-vision-capable model names, since Ollama's own model
    /// catalog already exposes this.
    func ensureVisionCapable(model: String) async throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw AISuggestionError.provider("No Ollama model selected")
        }

        var request = URLRequest(url: Self.tagsURL)
        request.timeoutInterval = Self.timeoutSeconds
        let (data, response) = try await performRequest(request)
        try Self.validate(response)

        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        guard let match = tags.models.first(where: { $0.name == trimmedModel || $0.model == trimmedModel })
        else {
            throw AISuggestionError.provider(
                "\"\(trimmedModel)\" was not found in Ollama — run `ollama pull \(trimmedModel)`")
        }
        let capabilities = (match.capabilities ?? []).map { $0.lowercased() }
        guard capabilities.contains("vision") else {
            throw AISuggestionError.provider("\"\(trimmedModel)\" does not support vision")
        }
    }

    func chat(
        model: String, systemPrompt: String, userPrompt: String, imagePayloads: [String], think: Bool
    ) async throws -> String {
        let payload = OllamaChatRequest(
            model: model,
            messages: [
                OllamaMessage(role: "system", content: systemPrompt, images: nil),
                OllamaMessage(role: "user", content: userPrompt, images: imagePayloads),
            ],
            options: OllamaOptions(temperature: 0.2),
            think: think ? nil : false,
            keepAlive: Self.keepAlive)

        var request = URLRequest(url: Self.chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeoutSeconds
        request.httpBody = try JSONEncoder().encode(payload)

        let payloadBytes = imagePayloads.reduce(0) { $0 + $1.utf8.count }
        let start = Date()
        let (data, response) = try await performRequest(request)
        let elapsedSeconds = Date().timeIntervalSince(start)
        Self.logger.log(
            "Ollama chat: model=\(model, privacy: .public) think=\(think, privacy: .public) elapsed=\(elapsedSeconds, privacy: .public)s payloadBytes=\(payloadBytes, privacy: .public)"
        )
        try Self.validate(response)

        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let content = (decoded.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AISuggestionError.emptyResponse }
        return content
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AISuggestionError.timeout
        } catch {
            throw AISuggestionError.provider(
                "Could not reach Ollama at 127.0.0.1:11434 — is `ollama serve` running? (\(error.localizedDescription))"
            )
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AISuggestionError.provider("Ollama returned status \(status)")
        }
    }
}

/// `think` and `images` are `Optional` so Swift's synthesized `Encodable` omits them from the JSON
/// body entirely when `nil` (via `encodeIfPresent`) — matching the Python payload builder, which
/// only includes `"think"` when explicitly `false` and only includes `"images"` on the user message.
private struct OllamaChatRequest: Encodable {
    var model: String
    var stream = false
    var messages: [OllamaMessage]
    var options: OllamaOptions
    var think: Bool?
    var keepAlive: String

    enum CodingKeys: String, CodingKey {
        case model, stream, messages, options, think
        case keepAlive = "keep_alive"
    }
}

private struct OllamaMessage: Codable {
    var role: String
    var content: String?
    var images: [String]?
}

private struct OllamaOptions: Encodable {
    var temperature: Double
}

private struct OllamaChatResponse: Decodable {
    var message: OllamaMessage?
}

private struct OllamaTagsResponse: Decodable {
    var models: [OllamaTagModel]
}

private struct OllamaTagModel: Decodable {
    var name: String?
    var model: String?
    var capabilities: [String]?
}
