import CoreImage
import ImageIO
import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Every test here needs both Adobe DNG Converter installed and a real RAW file in the gitignored
/// `samples/` directory, so each skips rather than fails when either is absent. What they cover that
/// `RawDevelopServiceTests` cannot is the one claim the whole via-DNG route rests on: that a body
/// Apple's decoder 9 does not list really does reach decoder 9 through a DNG.
final class AdobeDNGConverterTests: XCTestCase {
    private func makeConverter() throws -> AdobeDNGConverter {
        try XCTUnwrap(AdobeDNGConverter(), "Adobe DNG Converter is not installed")
    }

    private func sampleORF() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "samples/1066411_SanRafael_20260727_0929_OM-3_OM-100-400mm-F5.0-6.3-II.orf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdobeDNGConverterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testConvertToDNGProducesAFileReachingDecoderNine() async throws {
        let source = try sampleORF()
        let converter = try makeConverter()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let dngURL = try await converter.convertToDNG(source, outputDirectory: scratch)

        // Named after the original's stem, in the directory asked for — never beside the original,
        // which is typically a full SD card.
        XCTAssertEqual(dngURL.deletingPathExtension().lastPathComponent, source.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(dngURL.pathExtension, "dng")
        XCTAssertEqual(dngURL.deletingLastPathComponent().path, scratch.path)

        let filter = try XCTUnwrap(CIRAWFilter(imageURL: dngURL))
        XCTAssertTrue(filter.supportedDecoderVersions.map(\.rawValue).contains("9.dng"))
    }

    /// The end-to-end branch-2 claim: an OM-3 file, which on its own reports only decoders 7 and 8,
    /// renders at 9 once a converter is available, and the EXIF that lets the derivative join its
    /// original's capture set survives the round trip.
    func testDevelopViaDNGRendersAtDecoderNineAndKeepsCaptureMetadata() async throws {
        let source = try sampleORF()
        let converter = try makeConverter()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdobeDNGConverterTests-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        let result = try await RawDevelopService(dngConverter: converter)
            .develop(source, to: destination)

        XCTAssertEqual(result.decoderVersion, RawDevelopService.dngDecoderVersion)
        XCTAssertEqual(result.token, "RAW9")

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]

        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 5184)
        XCTAssertEqual(properties?[kCGImagePropertyPixelHeight] as? Int, 3888)
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "OM-3")
        XCTAssertNotNil(exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
    }
}
