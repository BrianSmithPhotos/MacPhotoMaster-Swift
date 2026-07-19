import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Exercises `EBirdSpeciesListService` against a mocked `URLSession` — no network access in CI,
/// no dependency on a real `EBIRD_API_KEY` being set. Mirrors `ReverseGeocodeServiceTests.swift`'s
/// mocking pattern.
final class EBirdSpeciesListServiceTests: XCTestCase {
    /// `APIKeyStore.resolve` falls back to the Keychain when the env var is unset, so a real key
    /// saved via `SettingsView` on this machine would otherwise leak into
    /// `testFetchTaxonomyThrowsMissingAPIKeyWhenUnset` — stash it away for the test and restore it
    /// after, rather than assuming the Keychain is empty.
    private var savedKeychainKey: String?

    override func setUp() {
        super.setUp()
        savedKeychainKey = APIKeyStore.read(account: "EBIRD_API_KEY")
        APIKeyStore.delete(account: "EBIRD_API_KEY")
        setenv("EBIRD_API_KEY", "test-key", 1)
    }

    override func tearDown() {
        MockEBirdURLProtocol.requestHandler = nil
        unsetenv("EBIRD_API_KEY")
        APIKeyStore.save(savedKeychainKey, account: "EBIRD_API_KEY")
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockEBirdURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func jsonResponse(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, body.data(using: .utf8)!)
    }

    func testFetchTaxonomyParsesRowsAndSkipsIncompleteOnes() async throws {
        MockEBirdURLProtocol.requestHandler = { [self] request in
            jsonResponse(
                for: request,
                body: #"""
                [
                    {"sciName": "Corvus corax", "comName": "Common Raven", "speciesCode": "comrav",
                     "category": "species"},
                    {"sciName": "Anser sp.", "comName": "goose sp.", "speciesCode": "x00776",
                     "category": "spuh"},
                    {"comName": "Missing fields"}
                ]
                """#)
        }
        let service = EBirdSpeciesListService(session: makeSession())

        let entries = try await service.fetchTaxonomy()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(
            entries.first,
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species"))
    }

    func testFetchTaxonomySetsAPIKeyHeader() async throws {
        var capturedRequest: URLRequest?
        MockEBirdURLProtocol.requestHandler = { [self] request in
            capturedRequest = request
            return jsonResponse(for: request, body: "[]")
        }
        let service = EBirdSpeciesListService(session: makeSession())

        _ = try await service.fetchTaxonomy()

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-eBirdApiToken"), "test-key")
    }

    func testFetchTaxonomyThrowsMissingAPIKeyWhenUnset() async {
        unsetenv("EBIRD_API_KEY")
        let service = EBirdSpeciesListService(session: makeSession())

        do {
            _ = try await service.fetchTaxonomy()
            XCTFail("Expected missingAPIKey")
        } catch let error as EBirdError {
            guard case .missingAPIKey = error else { return XCTFail("Expected .missingAPIKey, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFetchSubnational2RegionsParsesCodeAndName() async throws {
        MockEBirdURLProtocol.requestHandler = { [self] request in
            jsonResponse(for: request, body: #"[{"code": "US-CA-041", "name": "Marin"}]"#)
        }
        let service = EBirdSpeciesListService(session: makeSession())

        let regions = try await service.fetchSubnational2Regions(parentCode: "US-CA")

        XCTAssertEqual(regions, [EBirdSubnationalRegion(code: "US-CA-041", name: "Marin")])
    }

    func testFetchSpeciesCodesParsesFlatStringArray() async throws {
        MockEBirdURLProtocol.requestHandler = { [self] request in
            jsonResponse(for: request, body: #"["comrav", "houfin"]"#)
        }
        let service = EBirdSpeciesListService(session: makeSession())

        let codes = try await service.fetchSpeciesCodes(regionCode: "US-CA-041")

        XCTAssertEqual(codes, ["comrav", "houfin"])
    }

    func testGetThrowsInvalidResponseOnNon200Status() async {
        MockEBirdURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let service = EBirdSpeciesListService(session: makeSession())

        do {
            _ = try await service.fetchSpeciesCodes(regionCode: "bogus")
            XCTFail("Expected invalidResponse")
        } catch let error as EBirdError {
            guard case .invalidResponse = error else { return XCTFail("Expected .invalidResponse, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

private final class MockEBirdURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
