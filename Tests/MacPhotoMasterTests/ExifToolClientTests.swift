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

    func testBatchReadMetadataReturnsFileNameTagForEachURL() async throws {
        // Two arbitrary existing files is enough to prove the batched call maps results back
        // to each input URL rather than just returning the first file's metadata.
        let selfURL = URL(fileURLWithPath: #filePath)
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let client = ExifToolClient()

        let results = try await client.readMetadata(at: [selfURL, packageURL])

        guard case let .success(selfMetadata)? = results[selfURL] else {
            return XCTFail("expected success reading \(selfURL)")
        }
        guard case let .success(packageMetadata)? = results[packageURL] else {
            return XCTFail("expected success reading \(packageURL)")
        }
        XCTAssertEqual(selfMetadata["System:FileName"] as? String, selfURL.lastPathComponent)
        XCTAssertEqual(packageMetadata["System:FileName"] as? String, packageURL.lastPathComponent)
    }
}
