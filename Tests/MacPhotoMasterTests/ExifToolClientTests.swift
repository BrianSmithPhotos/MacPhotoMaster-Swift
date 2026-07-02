import XCTest
@testable import MacPhotoMaster

final class ExifToolClientTests: XCTestCase {
    func testReadMetadataReturnsFileNameTag() async throws {
        // Any file works for a smoke test; exiftool reads basic filesystem tags for anything.
        let selfURL = URL(fileURLWithPath: #filePath)
        let client = ExifToolClient()

        let metadata = try await client.readMetadata(at: selfURL)

        XCTAssertEqual(metadata["System:FileName"] as? String, selfURL.lastPathComponent)
    }
}
