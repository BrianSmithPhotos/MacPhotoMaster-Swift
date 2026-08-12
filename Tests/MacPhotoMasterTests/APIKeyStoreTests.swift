import XCTest

@testable import MacPhotoMasterCore

/// Guards the one property the rest of the suite's Keychain isolation rests on: that `service` is
/// honoured by all three operations, so pointing it at a throwaway name really does leave the
/// user's own items alone. `EBirdSpeciesListServiceTests` and `OpenRouterProviderTests` swap it in
/// `setUp` for exactly that reason — if a future edit hardcoded the service back into any one of
/// read/save/delete, those two would quietly go back to deleting and re-creating the real keys,
/// which is what made the app prompt for the Keychain once per suite run.
final class APIKeyStoreTests: XCTestCase {
    private let account = "TEST_ONLY_KEY"
    private var realService: String!

    override func setUp() {
        super.setUp()
        realService = APIKeyStore.service
        APIKeyStore.service = "photos.briansmith.macphotomaster.tests"
    }

    override func tearDown() {
        APIKeyStore.delete(account: account)
        APIKeyStore.service = realService
        super.tearDown()
    }

    func testTheStoreRoundTripsUnderWhicheverServiceIsSet() {
        XCTAssertNil(APIKeyStore.read(account: account), "the throwaway service starts empty")

        XCTAssertTrue(APIKeyStore.save("first", account: account))
        XCTAssertEqual(APIKeyStore.read(account: account), "first")

        // Second save takes the SecItemUpdate path rather than SecItemAdd — a separate branch, and
        // the one a hardcoded service would break without failing the add above.
        XCTAssertTrue(APIKeyStore.save("second", account: account))
        XCTAssertEqual(APIKeyStore.read(account: account), "second")

        XCTAssertTrue(APIKeyStore.delete(account: account))
        XCTAssertNil(APIKeyStore.read(account: account))
    }

    /// An empty value is a delete, not a blank secret — and it is the branch that turned a failed
    /// read into data loss back when the tests restored real keys through it.
    func testSavingNothingDeletes() {
        APIKeyStore.save("something", account: account)
        XCTAssertTrue(APIKeyStore.save(nil, account: account))
        XCTAssertNil(APIKeyStore.read(account: account))

        APIKeyStore.save("something", account: account)
        XCTAssertTrue(APIKeyStore.save("", account: account))
        XCTAssertNil(APIKeyStore.read(account: account))
    }
}
