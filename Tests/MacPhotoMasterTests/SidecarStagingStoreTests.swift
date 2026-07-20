import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacPhotoMasterCore

final class SidecarStagingStoreTests: XCTestCase {
    /// A tiny JPEG of `sizeBump` extra padding bytes appended after a valid JPEG EOI marker (still
    /// decodes fine, ImageIO ignores trailing bytes) — lets tests produce two source files with the
    /// same filename but different sizes, to exercise the filename+size staging key.
    private func writeBlankJPEG(to url: URL, sizeBump: Int = 0) throws {
        let pixel = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        pixel.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pixel.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = pixel.makeImage()!

        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        if sizeBump > 0 {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(Data(repeating: 0, count: sizeBump))
            try handle.close()
        }
    }

    private func makeTempFile(named name: String = "\(UUID().uuidString).jpg", sizeBump: Int = 0) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try writeBlankJPEG(to: url, sizeBump: sizeBump)
        return url
    }

    private func makeStore() throws -> SidecarStagingStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SidecarStagingStore(stagingDirectory: directory)
    }

    func testNoStagedDraftReturnsNil() throws {
        let url = try makeTempFile()
        let store = try makeStore()

        XCTAssertNil(try store.stagedDraft(for: url))
        XCTAssertFalse(try store.hasStagedDraft(for: url))
    }

    func testStageAndReadBackRoundTrip() async throws {
        let url = try makeTempFile()
        let store = try makeStore()

        try await store.stage(
            title: "My Title", description: "My description", keywords: ["mountain", "sunrise"],
            gps: GPSCoordinate(latitude: 45.5, longitude: -122.6, altitude: 30), for: url)

        XCTAssertTrue(try store.hasStagedDraft(for: url))
        let draft = try store.stagedDraft(for: url)
        XCTAssertEqual(draft?.title, "My Title")
        XCTAssertEqual(draft?.description, "My description")
        XCTAssertEqual(draft?.keywords, ["mountain", "sunrise"])
        // accuracy, not exact equality: XMP's text-based serialization introduces ~1e-14 double
        // round-trip noise (see SidecarStagingStore's doc comment) — irrelevant at GPS precision.
        XCTAssertEqual(draft?.gps?.latitude ?? 0, 45.5, accuracy: 1e-9)
        XCTAssertEqual(draft?.gps?.longitude ?? 0, -122.6, accuracy: 1e-9)
        XCTAssertEqual(draft?.gps?.altitude ?? 0, 30, accuracy: 1e-9)
    }

    func testStageWithNilTitleAndNoGPSReadsBackNil() async throws {
        let url = try makeTempFile()
        let store = try makeStore()

        try await store.stage(title: nil, description: "desc", keywords: [], gps: nil, for: url)

        let draft = try store.stagedDraft(for: url)
        XCTAssertNil(draft?.title)
        XCTAssertNil(draft?.gps)
        XCTAssertEqual(draft?.description, "desc")
    }

    func testRestagingOverwritesRatherThanDuplicating() async throws {
        let url = try makeTempFile()
        let store = try makeStore()

        try await store.stage(title: "First", description: "first desc", keywords: ["a"], gps: nil, for: url)
        try await store.stage(title: "Second", description: "second desc", keywords: ["b", "c"], gps: nil, for: url)

        let draft = try store.stagedDraft(for: url)
        XCTAssertEqual(draft?.title, "Second")
        XCTAssertEqual(draft?.description, "second desc")
        XCTAssertEqual(draft?.keywords, ["b", "c"])
    }

    /// The staging key is filename+size, not path — a file moved to a different directory (e.g.
    /// the DCIM folder rolling over between iPad review sessions, per docs/ARCHITECTURE.md) but
    /// with the same name and byte size must still resolve to the same staged draft.
    func testStagingKeyIgnoresSourcePath() async throws {
        let originalURL = try makeTempFile(named: "P1234567.JPG")
        let store = try makeStore()
        try await store.stage(title: "Staged", description: "desc", keywords: [], gps: nil, for: originalURL)

        let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: otherDirectory) }
        let movedURL = otherDirectory.appendingPathComponent("P1234567.JPG")
        try FileManager.default.copyItem(at: originalURL, to: movedURL)

        let draft = try store.stagedDraft(for: movedURL)
        XCTAssertEqual(draft?.title, "Staged")
    }

    /// Same filename, different byte size (e.g. a same-numbered shot from a reformatted card) must
    /// not collide with an unrelated staged draft.
    func testDifferentFileSizeDoesNotCollide() async throws {
        let firstURL = try makeTempFile(named: "P1234567.JPG")
        let secondURL = try makeTempFile(named: "P1234567.JPG", sizeBump: 4096)
        let store = try makeStore()

        try await store.stage(title: "First shot", description: "desc", keywords: [], gps: nil, for: firstURL)

        XCTAssertNil(try store.stagedDraft(for: secondURL))
    }
}
