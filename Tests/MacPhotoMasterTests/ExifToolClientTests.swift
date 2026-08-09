import XCTest
@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

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

    // MARK: - Error text

    /// Verbatim stderr from exiftool writing to a write-protected SD card (2026-08-09) — the failure
    /// that reported as a bare "62 failed" with the reason discarded. Without `LocalizedError` this
    /// renders as Foundation's "The operation couldn't be completed", which names nothing.
    func testProcessFailureReportsExifToolsOwnFirstErrorLine() {
        let stderr = """
            Error: Error creating file: /Volumes/OM SYSTEM/DCIM/107OMSYS/H1071885.JPG_exiftool_tmp \
            - /Volumes/OM SYSTEM/DCIM/107OMSYS/H1071885.JPG
            Error: Error creating file: /Volumes/OM SYSTEM/DCIM/107OMSYS/H1071886.JPG_exiftool_tmp \
            - /Volumes/OM SYSTEM/DCIM/107OMSYS/H1071886.JPG
            """
        let error = ExifToolError.processFailed(status: 1, stderr: stderr)

        // The first line only: a batch reports one error per file, near-always the same cause.
        XCTAssertEqual(
            error.localizedDescription,
            "Error: Error creating file: /Volumes/OM SYSTEM/DCIM/107OMSYS/H1071885.JPG_exiftool_tmp "
                + "- /Volumes/OM SYSTEM/DCIM/107OMSYS/H1071885.JPG")
        XCTAssertFalse(error.localizedDescription.contains("couldn't be completed"))
    }

    /// exiftool can exit non-zero with nothing on stderr, and a blank reason would be no better than
    /// the bare count this replaced.
    func testProcessFailureWithSilentStderrStillNamesTheStatus() {
        XCTAssertEqual(
            ExifToolError.processFailed(status: 2, stderr: "  \n \n").localizedDescription,
            "exiftool exited with status 2")
        XCTAssertEqual(
            ExifToolError.processFailed(status: 9, stderr: "").localizedDescription,
            "exiftool exited with status 9")
    }

    func testTimeoutAndUnreadableOutputAreNamed() {
        XCTAssertEqual(ExifToolError.timedOut.localizedDescription, "exiftool timed out")
        XCTAssertEqual(
            ExifToolError.invalidOutput.localizedDescription,
            "exiftool returned output that could not be read")
    }
}
