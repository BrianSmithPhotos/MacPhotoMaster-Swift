import Foundation
import os

/// Cloud backend for `AIProvider`, using OpenRouter's OpenAI-compatible chat-completions API.
/// Ported from the Python reference app's `services/openrouter_provider.py`: same endpoints, same
/// vision pre-check via `/api/models`' `architecture.input_modalities`, same app-attribution headers
/// so usage shows up under this app's name in the OpenRouter dashboard instead of "Unknown".
public struct OpenRouterProvider: AIProvider {
    private static let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    /// Matches the Python reference app's `OPENROUTER_TIMEOUT_SECONDS` default.
    private static let timeoutSeconds: TimeInterval = 120
    private static let appURL = "https://github.com/BrianSmithPhotos/MacPhotoMaster-Swift"
    private static let appName = "MacPhotoMaster"
    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "AISuggestion")

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// `OPENROUTER_API_KEY` env var wins if set (terminal/`swift run` debugging), else the value
    /// saved in `SettingsView`'s API Keys section (Keychain-backed) — see `APIKeyStore`.
    private static var apiKey: String? {
        APIKeyStore.resolve(envVar: "OPENROUTER_API_KEY", account: "OPENROUTER_API_KEY")
    }

    /// Throws `.provider(...)` if `model` is blank, isn't in OpenRouter's catalog, or doesn't
    /// advertise `"image"` in its `architecture.input_modalities` — matches the Python reference
    /// app's dynamic `/api/models` capability check rather than a hardcoded vision-model list.
    public func ensureVisionCapable(model: String) async throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw AISuggestionError.provider("No OpenRouter model selected")
        }

        var request = URLRequest(url: Self.modelsURL)
        request.timeoutInterval = Self.timeoutSeconds
        let (data, response) = try await performRequest(request, label: "models")
        try Self.validate(response, data: data)

        let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        guard let match = (decoded.data ?? []).first(where: { $0.id == trimmedModel }) else {
            throw AISuggestionError.provider(
                "OpenRouter model \"\(trimmedModel)\" was not found. Confirm the model id.")
        }
        let modalities = (match.architecture?.inputModalities ?? []).map { $0.lowercased() }
        guard modalities.contains("image") else {
            throw AISuggestionError.provider(
                "OpenRouter model \"\(trimmedModel)\" does not accept image input. Choose a model with vision capability."
            )
        }
    }

    public func chat(
        model: String, systemPrompt: String, userPrompt: String, imagePayloads: [String], think: Bool
    ) async throws -> String {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else {
            throw AISuggestionError.provider("OPENROUTER_API_KEY is not set")
        }

        var userContent: [OpenRouterContentPart] = [
            OpenRouterContentPart(type: "text", text: userPrompt, imageURL: nil)
        ]
        for payload in imagePayloads {
            userContent.append(
                OpenRouterContentPart(
                    type: "image_url", text: nil,
                    imageURL: .init(url: "data:image/jpeg;base64,\(payload)")))
        }
        let payload = OpenRouterChatRequest(
            model: model,
            messages: [
                OpenRouterMessage(role: "system", content: .text(systemPrompt)),
                OpenRouterMessage(role: "user", content: .parts(userContent)),
            ],
            temperature: 0.2,
            // Not all routed models support a reasoning toggle; harmless no-op when ignored.
            reasoning: think ? nil : OpenRouterReasoning(effort: "none", exclude: true))

        var request = URLRequest(url: Self.chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.appURL, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(Self.appName, forHTTPHeaderField: "X-OpenRouter-Title")
        request.timeoutInterval = Self.timeoutSeconds
        request.httpBody = try JSONEncoder().encode(payload)

        let payloadBytes = imagePayloads.reduce(0) { $0 + $1.utf8.count }
        let start = Date()
        let (data, response) = try await performRequest(request, label: "chat")
        let elapsedSeconds = Date().timeIntervalSince(start)
        Self.logger.log(
            "OpenRouter chat: model=\(model, privacy: .public) think=\(think, privacy: .public) elapsed=\(elapsedSeconds, privacy: .public)s payloadBytes=\(payloadBytes, privacy: .public)"
        )
        try Self.validate(response, data: data)

        let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        if let errorMessage = decoded.error?.message, !errorMessage.isEmpty {
            if Self.isTimeoutText(errorMessage) { throw AISuggestionError.timeout }
            throw AISuggestionError.provider(errorMessage)
        }
        let content =
            (decoded.choices?.first?.message?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AISuggestionError.emptyResponse }
        return content
    }

    private func performRequest(_ request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AISuggestionError.timeout
        } catch {
            throw AISuggestionError.provider(
                "Could not reach the OpenRouter API (\(label)): \(error.localizedDescription)")
        }
    }

    /// OpenRouter returns error detail in the JSON body even on non-2xx responses, so a bare status
    /// code isn't enough — decode `{"error": {"message": ...}}` when present, same as the Python
    /// reference app's `_error_message_from_body`.
    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = errorMessage(from: data) ?? "OpenRouter returned status \(status)"
            if isTimeoutText(message) { throw AISuggestionError.timeout }
            throw AISuggestionError.provider("OpenRouter request failed: \(message)")
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(OpenRouterChatResponse.self, from: data),
            let message = decoded.error?.message, !message.isEmpty
        else { return nil }
        return message
    }

    private static func isTimeoutText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("timed out") || lowered.contains("timeout")
    }
}

/// `Encodable` union of a plain-string system message vs. an array-of-parts user message — OpenAI-
/// compatible chat APIs allow either shape for `content`, and Swift's `Codable` has no built-in
/// union type.
private enum OpenRouterMessageContent: Encodable {
    case text(String)
    case parts([OpenRouterContentPart])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .parts(let value): try container.encode(value)
        }
    }
}

private struct OpenRouterContentPart: Encodable {
    public var type: String
    public var text: String?
    public var imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    struct ImageURL: Encodable {
        var url: String
    }
}

private struct OpenRouterMessage: Encodable {
    public var role: String
    public var content: OpenRouterMessageContent
}

private struct OpenRouterReasoning: Encodable {
    public var effort: String
    public var exclude: Bool
}

private struct OpenRouterChatRequest: Encodable {
    public var model: String
    public var messages: [OpenRouterMessage]
    public var temperature: Double
    public var reasoning: OpenRouterReasoning?
}

private struct OpenRouterChatResponse: Decodable {
    public var choices: [Choice]?
    public var error: APIError?

    struct Choice: Decodable {
        var message: MessageContent?
    }
    struct MessageContent: Decodable {
        var content: String?
    }
    struct APIError: Decodable {
        var message: String?
    }
}

private struct OpenRouterModelsResponse: Decodable {
    public var data: [OpenRouterModel]?
}

private struct OpenRouterModel: Decodable {
    public var id: String?
    public var architecture: Architecture?

    struct Architecture: Decodable {
        var inputModalities: [String]?
        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
        }
    }
}
