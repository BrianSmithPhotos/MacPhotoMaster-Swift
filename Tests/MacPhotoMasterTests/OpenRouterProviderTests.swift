import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Exercises `OpenRouterProvider`'s request-building/response-parsing against a mocked
/// `URLSession` (`MockURLProtocol` below) rather than the live OpenRouter API — no network access
/// or real API key needed in CI. Mirrors `OllamaProviderTests`' structure.
final class OpenRouterProviderTests: XCTestCase {
    /// `APIKeyStore.resolve` falls back to the Keychain when the env var is unset, so a real key
    /// saved via `SettingsView` on this machine would otherwise leak into
    /// `testChatThrowsProviderErrorWhenAPIKeyMissing` — stash it away for the test and restore it
    /// after, rather than assuming the Keychain is empty.
    private var savedKeychainKey: String?

    override func setUp() {
        super.setUp()
        savedKeychainKey = APIKeyStore.read(account: "OPENROUTER_API_KEY")
        APIKeyStore.delete(account: "OPENROUTER_API_KEY")
        setenv("OPENROUTER_API_KEY", "test-key", 1)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        unsetenv("OPENROUTER_API_KEY")
        APIKeyStore.save(savedKeychainKey, account: "OPENROUTER_API_KEY")
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func jsonResponse(for request: URLRequest, statusCode: Int = 200, body: String) -> (
        HTTPURLResponse, Data
    ) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, body.data(using: .utf8)!)
    }

    // MARK: - chat

    func testChatSendsBearerTokenAndAttributionHeaders() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return self.jsonResponse(
                for: request, body: #"{"choices": [{"message": {"content": "hello"}}]}"#)
        }
        let provider = OpenRouterProvider(session: makeSession())

        _ = try await provider.chat(
            model: "google/gemini-2.5-flash", systemPrompt: "sys", userPrompt: "user",
            imagePayloads: [], think: true)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "HTTP-Referer"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-OpenRouter-Title"))
    }

    func testChatSendsSystemMessageAsPlainStringAndUserMessageAsPartsArray() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            return self.jsonResponse(
                for: request, body: #"{"choices": [{"message": {"content": "hello"}}]}"#)
        }
        let provider = OpenRouterProvider(session: makeSession())

        _ = try await provider.chat(
            model: "google/gemini-2.5-flash", systemPrompt: "sys", userPrompt: "user",
            imagePayloads: ["abc123"], think: true)

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "google/gemini-2.5-flash")
        XCTAssertNil(json["reasoning"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["content"] as? String, "sys")
        let userParts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(userParts.count, 2)
        XCTAssertEqual(userParts[0]["type"] as? String, "text")
        XCTAssertEqual(userParts[0]["text"] as? String, "user")
        XCTAssertEqual(userParts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(userParts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/jpeg;base64,abc123")
    }

    func testChatIncludesReasoningKeyWhenThinkIsFalse() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody
            return self.jsonResponse(
                for: request, body: #"{"choices": [{"message": {"content": "hello"}}]}"#)
        }
        let provider = OpenRouterProvider(session: makeSession())

        _ = try await provider.chat(
            model: "google/gemini-2.5-flash", systemPrompt: "sys", userPrompt: "user",
            imagePayloads: [], think: false)

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
    }

    func testChatThrowsEmptyResponseWhenContentIsBlank() async {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(for: request, body: #"{"choices": [{"message": {"content": "  "}}]}"#)
        }
        let provider = OpenRouterProvider(session: makeSession())

        do {
            _ = try await provider.chat(
                model: "google/gemini-2.5-flash", systemPrompt: "sys", userPrompt: "user",
                imagePayloads: [], think: true)
            XCTFail("Expected an emptyResponse error")
        } catch let error as AISuggestionError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testChatThrowsProviderErrorWhenAPIKeyMissing() async {
        unsetenv("OPENROUTER_API_KEY")
        let provider = OpenRouterProvider(session: makeSession())

        do {
            _ = try await provider.chat(
                model: "google/gemini-2.5-flash", systemPrompt: "sys", userPrompt: "user",
                imagePayloads: [], think: true)
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider = error else { return XCTFail("Expected .provider, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testChatSurfacesHTTPErrorBodyMessage() async {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(
                for: request, statusCode: 402, body: #"{"error": {"message": "Insufficient credits"}}"#)
        }
        let provider = OpenRouterProvider(session: makeSession())

        do {
            _ = try await provider.chat(
                model: "google/gemini-2.5-flash", systemPrompt: "sys", userPrompt: "user",
                imagePayloads: [], think: true)
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider(let message) = error else {
                return XCTFail("Expected .provider, got \(error)")
            }
            XCTAssertTrue(message.contains("Insufficient credits"), "unexpected message: \(message)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - ensureVisionCapable

    func testEnsureVisionCapableSucceedsForVisionModel() async throws {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(
                for: request,
                body: #"""
                {"data": [{"id": "google/gemini-2.5-flash", "architecture": {"input_modalities": ["text", "image"]}}]}
                """#)
        }
        let provider = OpenRouterProvider(session: makeSession())

        try await provider.ensureVisionCapable(model: "google/gemini-2.5-flash")
    }

    func testEnsureVisionCapableThrowsForNonVisionModel() async {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(
                for: request,
                body: #"""
                {"data": [{"id": "openai/gpt-4o-mini", "architecture": {"input_modalities": ["text"]}}]}
                """#)
        }
        let provider = OpenRouterProvider(session: makeSession())

        do {
            try await provider.ensureVisionCapable(model: "openai/gpt-4o-mini")
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider = error else { return XCTFail("Expected .provider, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testEnsureVisionCapableThrowsWhenModelNotFound() async {
        MockURLProtocol.requestHandler = { request in
            self.jsonResponse(for: request, body: #"{"data": []}"#)
        }
        let provider = OpenRouterProvider(session: makeSession())

        do {
            try await provider.ensureVisionCapable(model: "google/gemini-2.5-flash")
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider = error else { return XCTFail("Expected .provider, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testEnsureVisionCapableThrowsForBlankModel() async {
        let provider = OpenRouterProvider(session: makeSession())

        do {
            try await provider.ensureVisionCapable(model: "   ")
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider = error else { return XCTFail("Expected .provider, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // `URLSession` delivers the body to a custom `URLProtocol` via `httpBodyStream` rather
        // than `httpBody`, even though the original `URLRequest` was built with `httpBody` set —
        // reconstitute it so the handler can inspect the JSON payload the same way either way.
        var effectiveRequest = request
        if effectiveRequest.httpBody == nil, let stream = request.httpBodyStream {
            effectiveRequest.httpBody = Self.readAllData(from: stream)
        }
        do {
            let (response, data) = try handler(effectiveRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAllData(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}
