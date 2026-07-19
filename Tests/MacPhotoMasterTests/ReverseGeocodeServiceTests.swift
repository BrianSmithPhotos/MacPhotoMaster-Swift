import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Exercises `ReverseGeocodeService` against a mocked `URLSession` (`MockURLProtocol` below) rather
/// than live Nominatim — no network access in CI. Mirrors `OllamaProviderTests.swift`'s mocking
/// pattern.
final class ReverseGeocodeServiceTests: XCTestCase {
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

    func testLookupLocationParsesCityCountyState() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(
                for: request,
                body: #"""
                {"address": {"city": "Portland", "county": "Multnomah County", "state": "Oregon"}}
                """#)
        }
        let service = ReverseGeocodeService(session: makeSession())

        let result = try await service.lookupLocation(latitude: 45.5, longitude: -122.6)

        XCTAssertEqual(result.city, "Portland")
        XCTAssertEqual(result.county, "Multnomah County")
        XCTAssertEqual(result.state, "Oregon")
    }

    func testLookupLocationParsesISO3166Lvl4AsStateRegionCode() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(
                for: request,
                body: #"""
                {"address": {"city": "San Rafael", "county": "Marin County", "state": "California",
                              "ISO3166-2-lvl4": "US-CA"}}
                """#)
        }
        let service = ReverseGeocodeService(session: makeSession())

        let result = try await service.lookupLocation(latitude: 37.9735, longitude: -122.5311)

        XCTAssertEqual(result.stateRegionCode, "US-CA")
    }

    func testLookupLocationLeavesStateRegionCodeNilWhenAbsent() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(for: request, body: #"{"address": {"state": "Oregon"}}"#)
        }
        let service = ReverseGeocodeService(session: makeSession())

        let result = try await service.lookupLocation(latitude: 45.5, longitude: -122.6)

        XCTAssertNil(result.stateRegionCode)
    }

    func testLookupLocationFallsBackThroughLocalityKeysWhenCityIsMissing() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(
                for: request, body: #"{"address": {"village": "Cascade Locks", "state": "Oregon"}}"#)
        }
        let service = ReverseGeocodeService(session: makeSession())

        let result = try await service.lookupLocation(latitude: 45.6, longitude: -121.9)

        XCTAssertEqual(result.city, "Cascade Locks")
        XCTAssertEqual(result.county, "")
        XCTAssertEqual(result.state, "Oregon")
    }

    func testLookupLocationSetsUserAgentAndQueryParameters() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { [self] request in
            capturedRequest = request
            return jsonResponse(for: request, body: #"{"address": {"state": "Oregon"}}"#)
        }
        let service = ReverseGeocodeService(session: makeSession())

        _ = try await service.lookupLocation(latitude: 45.5, longitude: -122.6)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(queryItems.first { $0.name == "lat" }?.value, "45.5000000")
        XCTAssertEqual(queryItems.first { $0.name == "lon" }?.value, "-122.6000000")
    }

    func testLookupLocationThrowsNoLocationFoundWhenAddressHasNoUsableFields() async {
        MockURLProtocol.requestHandler = { [self] request in
            jsonResponse(for: request, body: #"{"address": {"country": "United States"}}"#)
        }
        let service = ReverseGeocodeService(session: makeSession())

        do {
            _ = try await service.lookupLocation(latitude: 45.5, longitude: -122.6)
            XCTFail("Expected noLocationFound")
        } catch let error as ReverseGeocodeError {
            guard case .noLocationFound = error else { return XCTFail("Expected .noLocationFound, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testLookupLocationWrapsRequestFailure() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let service = ReverseGeocodeService(session: makeSession())

        do {
            _ = try await service.lookupLocation(latitude: 45.5, longitude: -122.6)
            XCTFail("Expected requestFailed")
        } catch let error as ReverseGeocodeError {
            guard case .requestFailed = error else { return XCTFail("Expected .requestFailed, got \(error)") }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - ReverseGeocodeResult

    func testKeywordTokensDropsBlankFields() {
        let result = ReverseGeocodeResult(city: "Portland", county: "", state: "Oregon")
        XCTAssertEqual(result.keywordTokens, ["Portland", "Oregon"])
    }

    func testContextTextJoinsOnlyPresentFields() {
        let result = ReverseGeocodeResult(city: "Portland", county: "", state: "Oregon")
        XCTAssertEqual(result.contextText, "city=Portland; state=Oregon")
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
