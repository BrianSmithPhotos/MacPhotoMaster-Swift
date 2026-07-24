import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class ExifToolClientWriteTests: XCTestCase {
    /// A tiny 1x1 JPEG with no metadata of its own — exiftool's write path doesn't need real
    /// image content to attach IPTC/XMP/GPS tags to, and generating this in-memory keeps these
    /// tests independent of any real photo file (see CLAUDE.md "Secrets & Privacy").
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

    func testSingleFileWriteRoundTripsThroughReadMetadata() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()
        let gps = GPSCoordinate(latitude: 45.5, longitude: -122.6, altitude: 30)

        try await client.write(
            title: "My Title", description: "My description", keywords: ["mountain", "sunrise"],
            gps: gps, to: url)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:ObjectName"] as? String, "My Title")
        XCTAssertEqual(metadata["XMP-dc:Title"] as? String, "My Title")
        XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "My description")
        XCTAssertEqual(metadata["XMP-dc:Description"] as? String, "My description")
        XCTAssertEqual(metadata["XMP-iptcCore:AltTextAccessibility"] as? String, "My description")
        XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["mountain", "sunrise"])
        XCTAssertEqual(metadata["XMP-dc:Subject"] as? [String], ["mountain", "sunrise"])
        // Read output isn't `-n` (numeric), so GPS comes back as exiftool's human-readable
        // hemisphere-annotated strings rather than raw signed doubles — the sign-derivation tests
        // below cover the Ref tags directly.
        XCTAssertEqual(metadata["GPS:GPSLatitudeRef"] as? String, "North")
        XCTAssertEqual(metadata["GPS:GPSLongitudeRef"] as? String, "West")
    }

    func testSingleFileWriteCleansUpBackupOnSuccess() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()

        try await client.write(title: nil, description: "desc", keywords: [], gps: nil, to: url)

        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "_original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testIdempotentKeywordResaveDoesNotDuplicate() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()

        try await client.write(title: nil, description: "desc", keywords: ["mountain", "Sunrise"], gps: nil, to: url)
        try await client.write(title: nil, description: "desc", keywords: ["Mountain", "sunrise"], gps: nil, to: url)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["Mountain", "sunrise"])
        XCTAssertEqual(metadata["XMP-dc:Subject"] as? [String], ["Mountain", "sunrise"])
    }

    func testGPSRefDerivationForAllFourHemisphereCombinations() async throws {
        let client = ExifToolClient()
        // exiftool's default (non-numeric) read output spells these out rather than the raw
        // N/S/E/W byte exiftool was given on write.
        let cases: [(lat: Double, lon: Double, latRef: String, lonRef: String)] = [
            (45.5, 122.6, "North", "East"),
            (45.5, -122.6, "North", "West"),
            (-45.5, 122.6, "South", "East"),
            (-45.5, -122.6, "South", "West"),
        ]

        for testCase in cases {
            let url = try makeTempFile()
            try await client.write(
                title: nil, description: "desc", keywords: [],
                gps: GPSCoordinate(latitude: testCase.lat, longitude: testCase.lon, altitude: nil), to: url)

            let metadata = try await client.readMetadata(at: url)
            XCTAssertEqual(metadata["GPS:GPSLatitudeRef"] as? String, testCase.latRef)
            XCTAssertEqual(metadata["GPS:GPSLongitudeRef"] as? String, testCase.lonRef)
        }
    }

    func testGPSAltitudeRefDerivationForBothSigns() async throws {
        let client = ExifToolClient()

        let aboveSeaLevel = try makeTempFile()
        try await client.write(
            title: nil, description: "desc", keywords: [],
            gps: GPSCoordinate(latitude: 1, longitude: 1, altitude: 30), to: aboveSeaLevel)
        let aboveMetadata = try await client.readMetadata(at: aboveSeaLevel)
        XCTAssertEqual(aboveMetadata["GPS:GPSAltitudeRef"] as? String, "Above Sea Level")

        let belowSeaLevel = try makeTempFile()
        try await client.write(
            title: nil, description: "desc", keywords: [],
            gps: GPSCoordinate(latitude: 1, longitude: 1, altitude: -30), to: belowSeaLevel)
        let belowMetadata = try await client.readMetadata(at: belowSeaLevel)
        XCTAssertEqual(belowMetadata["GPS:GPSAltitudeRef"] as? String, "Below Sea Level")
    }

    func testInvalidGPSCoordinateThrows() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()

        do {
            try await client.write(
                title: nil, description: "desc", keywords: [],
                gps: GPSCoordinate(latitude: 200, longitude: 0, altitude: nil), to: url)
            XCTFail("expected invalidLatitude to be thrown")
        } catch MetadataWriteError.invalidLatitude(let value) {
            XCTAssertEqual(value, 200)
        }
    }

    func testBatchWriteAppliesValuesToAllFiles() async throws {
        let urls = try [makeTempFile(), makeTempFile(), makeTempFile()]
        let client = ExifToolClient()

        let results = try await client.write(description: "shared desc", keywords: ["one", "two"], gps: nil, to: urls)

        for url in urls {
            guard case .success = results[url] else {
                return XCTFail("expected success for \(url)")
            }
            let metadata = try await client.readMetadata(at: url)
            XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "shared desc")
            XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["one", "two"])
        }
    }

    func testBatchWriteRollsBackAndFallsBackPerFileWhenOnePathIsInvalid() async throws {
        let goodURLs = try [makeTempFile(), makeTempFile()]
        let badURL = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).jpg")
        let client = ExifToolClient()

        let results = try await client.write(
            description: "shared desc", keywords: ["shared"], gps: nil, to: goodURLs + [badURL])

        for url in goodURLs {
            guard case .success = results[url] else {
                return XCTFail("expected the good files to succeed via per-file fallback")
            }
            let metadata = try await client.readMetadata(at: url)
            XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "shared desc")

            let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "_original")
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }

        guard case .failure = results[badURL] else {
            return XCTFail("expected the nonexistent file to fail")
        }
    }
}
