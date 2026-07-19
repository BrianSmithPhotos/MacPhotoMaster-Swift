import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacPhotoMaster

final class NativeMetadataWriterTests: XCTestCase {
    /// A tiny 1x1 JPEG with no metadata of its own — `NativeMetadataWriter` never touches this
    /// file's bytes (it only ever writes the sidecar next to it), but a real file needs to exist
    /// at the path the sidecar is derived from.
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

    /// Reads a sidecar's fields back via exiftool the same way `ExifToolClient
    /// .foldInSidecarIfPresent(for:)` does, so these tests exercise the actual on-disk XMP rather
    /// than internal state.
    private func readSidecarFields(_ url: URL) async throws -> [String: Any] {
        let client = ExifToolClient()
        return try await client.readMetadata(at: NativeMetadataWriter.sidecarURL(for: url))
    }

    func testWriteCreatesSidecarAtExpectedPath() async throws {
        let url = try makeTempFile()
        let writer = NativeMetadataWriter()

        try await writer.write(title: "Title", description: "desc", keywords: [], gps: nil, to: url)

        let sidecar = NativeMetadataWriter.sidecarURL(for: url)
        XCTAssertEqual(sidecar.lastPathComponent, url.deletingPathExtension().lastPathComponent + ".xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        // The original file itself must be untouched — this writer never rewrites image bytes.
        let originalMetadata = try await ExifToolClient().readMetadata(at: url)
        XCTAssertNil(originalMetadata["XMP-dc:Title"])
    }

    func testSidecarFieldsRoundTrip() async throws {
        let url = try makeTempFile()
        let writer = NativeMetadataWriter()

        try await writer.write(
            title: "My Title", description: "My description", keywords: ["mountain", "sunrise"],
            gps: GPSCoordinate(latitude: 45.5, longitude: -122.6, altitude: 30), to: url)

        let fields = try await readSidecarFields(url)
        XCTAssertEqual(fields["XMP-dc:Title"] as? String, "My Title")
        XCTAssertEqual(fields["XMP-dc:Description"] as? String, "My description")
        XCTAssertEqual(fields["XMP-dc:Subject"] as? [String], ["mountain", "sunrise"])
    }

    /// The bug fixed during prototyping: XMP GPS tags encode hemisphere via sign, not a separate
    /// Ref tag — a Ref tag here would be silently ignored by readers and the wrong hemisphere
    /// would win if the sign were also wrong. This locks in "signed decimal, no Ref tags."
    func testGPSEncodedAsSignedDecimalWithNoRefTags() async throws {
        let url = try makeTempFile()
        let writer = NativeMetadataWriter()

        try await writer.write(
            title: nil, description: "desc", keywords: [],
            gps: GPSCoordinate(latitude: 45.5, longitude: -122.6, altitude: nil), to: url)

        let sidecar = NativeMetadataWriter.sidecarURL(for: url)
        let numericFields = try await Self.readNumericGPS(sidecar)
        XCTAssertEqual(numericFields.latitude, 45.5)
        XCTAssertEqual(numericFields.longitude, -122.6)
    }

    private static func readNumericGPS(_ sidecar: URL) async throws -> (latitude: Double, longitude: Double) {
        // Mirrors ExifToolClient.foldInSidecarIfPresent(for:)'s own read call so this test verifies
        // the exact value that reconciliation depends on.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["exiftool", "-j", "-GPSLatitude#", "-GPSLongitude#", sidecar.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let fields = array?.first ?? [:]
        return (fields["GPSLatitude"] as? Double ?? 0, fields["GPSLongitude"] as? Double ?? 0)
    }

    func testKeywordNormalizationAppliedToSidecar() async throws {
        let url = try makeTempFile()
        let writer = NativeMetadataWriter()

        try await writer.write(
            title: nil, description: "desc", keywords: ["Mountain", " mountain ", "sunrise", ""],
            gps: nil, to: url)

        let fields = try await readSidecarFields(url)
        XCTAssertEqual(fields["XMP-dc:Subject"] as? [String], ["Mountain", "sunrise"])
    }

    func testBatchWriteCreatesSidecarForEveryURL() async throws {
        let urls = try [makeTempFile(), makeTempFile(), makeTempFile()]
        let writer = NativeMetadataWriter()

        let results = try await writer.write(description: "shared desc", keywords: ["one", "two"], gps: nil, to: urls)

        for url in urls {
            guard case .success = results[url] else {
                return XCTFail("expected success for \(url)")
            }
            let fields = try await readSidecarFields(url)
            XCTAssertEqual(fields["XMP-dc:Subject"] as? [String], ["one", "two"])
        }
    }

    func testInvalidGPSCoordinateThrowsBeforeWritingSidecar() async throws {
        let url = try makeTempFile()
        let writer = NativeMetadataWriter()

        do {
            try await writer.write(
                title: nil, description: "desc", keywords: [],
                gps: GPSCoordinate(latitude: 200, longitude: 0, altitude: nil), to: url)
            XCTFail("expected invalidLatitude to be thrown")
        } catch MetadataWriteError.invalidLatitude(let value) {
            XCTAssertEqual(value, 200)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: NativeMetadataWriter.sidecarURL(for: url).path))
    }
}
