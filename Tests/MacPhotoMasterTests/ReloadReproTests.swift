import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class ReloadReproTests: XCTestCase {
    func testWriteThenReloadViaPhotoAssetLoaderRoundTripsDescription() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let pixel = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixel.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pixel.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = pixel.makeImage()!
        let url = sourceDirectory.appendingPathComponent("P1010042.JPG")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let client = ExifToolClient()
        try await client.write(
            title: nil, description: "My description", keywords: ["mountain", "sunrise"], gps: nil, to: url)

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let asset = try XCTUnwrap(assets.first)

        print("RELOADED descriptionText = '\(asset.descriptionText)'")
        print("RELOADED keywords = \(asset.keywords)")
        XCTAssertEqual(asset.descriptionText, "My description")
        XCTAssertEqual(asset.keywords, ["mountain", "sunrise"])
    }

    /// Reproduces the user's real-world scenario against an actual OM SYSTEM ORF that already has
    /// pre-existing IPTC fields (Copyright, Byline, StarRating) baked in from the camera — closer to
    /// the real card than a blank synthetic fixture. Skips itself when the card isn't mounted.
    func testWriteRealisticDescriptionThenReloadRealORF() async throws {
        let cardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.ORF")
        guard FileManager.default.fileExists(atPath: cardURL.path) else {
            throw XCTSkip("SD card not mounted")
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let url = sourceDirectory.appendingPathComponent("F1052228.ORF")
        try FileManager.default.copyItem(at: cardURL, to: url)

        let realisticDescription =
            "A red-tailed hawk perched on a weathered fence post, scanning the golden grassland at dusk."
        let client = ExifToolClient()
        try await client.write(
            title: nil, description: realisticDescription, keywords: ["hawk", "wildlife", "grassland"],
            gps: nil, to: url)

        let viaExifTool = try await client.readMetadata(at: url)
        print("VIA EXIFTOOL Caption-Abstract = '\(viaExifTool["IPTC:Caption-Abstract"] ?? "nil")'")
        print("VIA EXIFTOOL Keywords = \(viaExifTool["IPTC:Keywords"] ?? "nil")")

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let asset = try XCTUnwrap(assets.first)
        print("RELOADED (real ORF) descriptionText = '\(asset.descriptionText)'")
        print("RELOADED (real ORF) keywords = \(asset.keywords)")

        XCTAssertEqual(asset.descriptionText, realisticDescription)
        XCTAssertEqual(asset.keywords, ["hawk", "wildlife", "grassland"])
    }

    /// Simulates a second save overwriting a first (AI auto-save, then a manual edit + save) — the
    /// exact sequence the user reported.
    func testSecondSaveWithDifferentDescriptionOverwritesFirst() async throws {
        let cardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.ORF")
        guard FileManager.default.fileExists(atPath: cardURL.path) else {
            throw XCTSkip("SD card not mounted")
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let url = sourceDirectory.appendingPathComponent("F1052228.ORF")
        try FileManager.default.copyItem(at: cardURL, to: url)

        let client = ExifToolClient()
        try await client.write(
            title: nil, description: "AI generated description of a hawk.", keywords: ["hawk"], gps: nil,
            to: url)
        try await client.write(
            title: nil, description: "Manually edited description of a hawk on a post.",
            keywords: ["hawk", "post"], gps: nil, to: url)

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let asset = try XCTUnwrap(assets.first)
        print("AFTER SECOND SAVE descriptionText = '\(asset.descriptionText)'")
        print("AFTER SECOND SAVE keywords = \(asset.keywords)")

        XCTAssertEqual(asset.descriptionText, "Manually edited description of a hawk on a post.")
        XCTAssertEqual(asset.keywords, ["hawk", "post"])
    }

    /// Documents a confirmed ImageIO limitation (see `NativeMetadataReader`'s doc comment): on a
    /// real OM SYSTEM camera JPEG, `PhotoAssetLoader`'s ImageIO-based scan reads back an empty
    /// description even though `exiftool` wrote — and independently reads back — the correct
    /// value. Verified down to the raw IPTC IIM bytes (the `2:120` Caption-Abstract dataset is
    /// present and correct on disk); this is not a write bug, and not reproducible with a
    /// synthetic fixture. `SourceBrowserViewModel.loadArtFilterTokenIfNeeded()` is where this gets
    /// corrected (one `exiftool` read per selected asset, same mechanism already used for
    /// maker-note fields) — that correction lives one layer up from `PhotoAssetLoader`, so this
    /// test asserts the gap `PhotoAssetLoader` alone still has, as a regression lock: if this
    /// starts passing (Apple fixes the ImageIO parsing, or `NativeMetadataReader` changes), the
    /// ViewModel-level workaround may no longer be necessary.
    func testSingleFileWriteToRealCameraJPEGThenReload_documentsImageIODescriptionGap() async throws {
        let jpegCardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.JPG")
        guard FileManager.default.fileExists(atPath: jpegCardURL.path) else {
            throw XCTSkip("SD card not mounted")
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let jpegURL = sourceDirectory.appendingPathComponent("F1052228.JPG")
        try FileManager.default.copyItem(at: jpegCardURL, to: jpegURL)

        let client = ExifToolClient()
        let description = "A red-tailed hawk perched on a weathered fence post at dusk."
        try await client.write(
            title: nil, description: description, keywords: ["hawk", "wildlife"], gps: nil, to: jpegURL)

        let viaExifTool = try await client.readMetadata(at: jpegURL)
        XCTAssertEqual(viaExifTool["IPTC:Caption-Abstract"] as? String, description)

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let asset = try XCTUnwrap(assets.first)
        XCTAssertEqual(asset.descriptionText, "", "ImageIO read this file's Caption-Abstract correctly — if so, NativeMetadataReader's doc comment and loadArtFilterTokenIfNeeded's workaround may no longer be needed.")
    }

    /// `saveMetadata(scope: .captureSet(...))` uses the *batched* multi-URL write, not the
    /// single-file one exercised above — reproduces that exact path on a real RAW+JPEG pair, and
    /// confirms the ImageIO gap above is JPEG-specific: the ORF sibling in the same batch reads
    /// back correctly.
    func testBatchedWriteToRAWPlusJPEGPairThenReloadBoth_documentsImageIODescriptionGapOnJPEGOnly() async throws {
        let jpegCardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.JPG")
        let rawCardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.ORF")
        guard FileManager.default.fileExists(atPath: jpegCardURL.path),
            FileManager.default.fileExists(atPath: rawCardURL.path)
        else {
            throw XCTSkip("SD card not mounted")
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let jpegURL = sourceDirectory.appendingPathComponent("F1052228.JPG")
        let rawURL = sourceDirectory.appendingPathComponent("F1052228.ORF")
        try FileManager.default.copyItem(at: jpegCardURL, to: jpegURL)
        try FileManager.default.copyItem(at: rawCardURL, to: rawURL)

        let client = ExifToolClient()
        let description = "A red-tailed hawk perched on a weathered fence post at dusk."
        let results = try await client.write(
            description: description, keywords: ["hawk", "wildlife"], gps: nil, to: [jpegURL, rawURL])
        for (url, result) in results {
            if case .failure(let error) = result {
                XCTFail("write failed for \(url.lastPathComponent): \(error)")
            }
        }

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let assetsByExtension = Dictionary(uniqueKeysWithValues: assets.map { ($0.url.pathExtension.uppercased(), $0) })

        XCTAssertEqual(assetsByExtension["ORF"]?.descriptionText, description)
        XCTAssertEqual(assetsByExtension["JPG"]?.descriptionText, "", "see NativeMetadataReader's doc comment — JPEG-only ImageIO description gap.")
        for asset in assets {
            XCTAssertEqual(asset.keywords, ["hawk", "wildlife"], "mismatch for \(asset.url.lastPathComponent)")
        }
    }
}
