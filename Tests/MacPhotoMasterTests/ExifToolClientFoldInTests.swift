import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacPhotoMaster

final class ExifToolClientFoldInTests: XCTestCase {
    /// A tiny 1x1 JPEG with no metadata of its own — matches the fixture convention used by
    /// `ExifToolClientWriteTests` and `NativeMetadataWriterTests`.
    private func writeBlankJPEG(to url: URL) throws {
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
    }

    private func makeTempFile(named name: String = "\(UUID().uuidString).jpg") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try writeBlankJPEG(to: url)
        return url
    }

    func testFoldInReturnsFalseWhenNoSidecarExists() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()

        let folded = try await client.foldInSidecarIfPresent(for: url)

        XCTAssertFalse(folded)
    }

    func testFoldInWritesSidecarFieldsIntoOriginalAndDeletesSidecar() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()
        let nativeWriter = NativeMetadataWriter()

        try await nativeWriter.write(
            title: "Sidecar Title", description: "Sidecar description",
            keywords: ["mountain", "sunrise"],
            gps: GPSCoordinate(latitude: 45.5, longitude: -122.6, altitude: nil), to: url)

        let folded = try await client.foldInSidecarIfPresent(for: url)

        XCTAssertTrue(folded)
        let sidecar = NativeMetadataWriter.sidecarURL(for: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["XMP-dc:Title"] as? String, "Sidecar Title")
        XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "Sidecar description")
        XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["mountain", "sunrise"])
        XCTAssertEqual(metadata["GPS:GPSLatitudeRef"] as? String, "North")
        XCTAssertEqual(metadata["GPS:GPSLongitudeRef"] as? String, "West")
    }

    func testFoldInWithNoGPSInSidecarLeavesGPSUnset() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()
        let nativeWriter = NativeMetadataWriter()

        try await nativeWriter.write(title: nil, description: "desc only", keywords: [], gps: nil, to: url)

        let folded = try await client.foldInSidecarIfPresent(for: url)
        XCTAssertTrue(folded)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "desc only")
        XCTAssertNil(metadata["GPS:GPSLatitudeRef"])
    }

    func testRefoldingAfterAnotherSidecarWriteDoesNotDuplicateKeywords() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()
        let nativeWriter = NativeMetadataWriter()

        try await nativeWriter.write(title: nil, description: "desc", keywords: ["mountain"], gps: nil, to: url)
        _ = try await client.foldInSidecarIfPresent(for: url)

        try await nativeWriter.write(title: nil, description: "desc", keywords: ["Mountain", "sunrise"], gps: nil, to: url)
        _ = try await client.foldInSidecarIfPresent(for: url)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["Mountain", "sunrise"])
    }
}
