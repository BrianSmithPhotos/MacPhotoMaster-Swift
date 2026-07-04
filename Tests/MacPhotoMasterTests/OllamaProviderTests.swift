import XCTest

@testable import MacPhotoMaster

/// Exercises `OllamaProvider`'s request-building/response-parsing against a mocked `URLSession`
/// (`MockURLProtocol` below) rather than a live `ollama serve` — no network access in CI, but still
/// real coverage of the JSON payload shape and the `/api/tags` capability check, not just the pure
/// helpers the plan originally scoped this down to.
final class OllamaProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func jsonResponse(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, body.data(using: .utf8)!)
    }

    // MARK: - chat

    func testChatOmitsThinkKeyWhenThinkIsTrue() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { [self] request in
            capturedBody = request.httpBody
            return jsonResponse(for: request, body: #"{"message": {"role": "assistant", "content": "hello"}}"#)
        }
        let provider = OllamaProvider(session: makeSession())

        let content = try await provider.chat(
            model: "qwen3.6:35b", systemPrompt: "sys", userPrompt: "user", imagePayloads: ["abc123"], think: true)

        XCTAssertEqual(content, "hello")
        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["think"])
        XCTAssertEqual(json["keep_alive"] as? String, "15m")
        XCTAssertEqual(json["model"] as? String, "qwen3.6:35b")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1]["images"] as? [String], ["abc123"])
    }

    func testChatIncludesThinkFalseKeyWhenThinkIsFalse() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { [self] request in
            capturedBody = request.httpBody
            return jsonResponse(for: request, body: #"{"message": {"role": "assistant", "content": "hello"}}"#)
        }
        let provider = OllamaProvider(session: makeSession())

        _ = try await provider.chat(
            model: "qwen3.6:35b", systemPrompt: "sys", userPrompt: "user", imagePayloads: ["abc123"], think: false)

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["think"] as? Bool, false)
    }

    func testChatThrowsEmptyResponseWhenContentIsBlank() async {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(for: request, body: #"{"message": {"role": "assistant", "content": "  "}}"#)
        }
        let provider = OllamaProvider(session: makeSession())

        do {
            _ = try await provider.chat(
                model: "qwen3.6:35b", systemPrompt: "sys", userPrompt: "user", imagePayloads: [], think: true)
            XCTFail("Expected an emptyResponse error")
        } catch let error as AISuggestionError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - ensureVisionCapable

    func testEnsureVisionCapableSucceedsForVisionModel() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(
                for: request,
                body: #"{"models": [{"name": "qwen3.6:35b", "capabilities": ["completion", "vision"]}]}"#)
        }
        let provider = OllamaProvider(session: makeSession())

        try await provider.ensureVisionCapable(model: "qwen3.6:35b")
    }

    func testEnsureVisionCapableThrowsForNonVisionModel() async {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(
                for: request, body: #"{"models": [{"name": "llama3.2:1b", "capabilities": ["completion"]}]}"#)
        }
        let provider = OllamaProvider(session: makeSession())

        do {
            try await provider.ensureVisionCapable(model: "llama3.2:1b")
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider = error else { return XCTFail("Expected .provider, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testEnsureVisionCapableThrowsWhenModelNotFound() async {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(for: request, body: #"{"models": []}"#)
        }
        let provider = OllamaProvider(session: makeSession())

        do {
            try await provider.ensureVisionCapable(model: "qwen3.6:35b")
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            guard case .provider = error else { return XCTFail("Expected .provider, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testEnsureVisionCapableThrowsForBlankModel() async {
        let provider = OllamaProvider(session: makeSession())

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
