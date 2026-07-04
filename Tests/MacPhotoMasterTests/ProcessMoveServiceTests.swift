import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacPhotoMaster

final class ProcessMoveServiceTests: XCTestCase {
    /// A tiny 1x1 JPEG with no metadata of its own — matches `ExifToolClientWriteTests`' fixture so
    /// these tests don't depend on any real photo file (see CLAUDE.md "Secrets & Privacy").
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

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeSourceJPEG(named name: String = "P1010042.JPG", in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try writeBlankJPEG(to: url)
        return url
    }

    private func renameContext(for asset: PhotoAsset) -> RenameContext {
        RenameContext(
            sourceURL: asset.url,
            capturedAt: asset.capturedAt,
            cameraModel: asset.cameraModel,
            lensModel: asset.lensModel,
            batch: "Yosemite",
            artFilterToken: asset.artFilterToken)
    }

    func testProcessAndCopyVerifiesAndWritesMetadataToDestination() async throws {
        let sourceDirectory = try makeTempDirectory()
        let libraryRoot = try makeTempDirectory()
        let sourceURL = try makeSourceJPEG(in: sourceDirectory)

        var asset = PhotoAsset(id: sourceURL)
        asset.descriptionText = "My description"
        asset.keywords = ["mountain", "sunrise"]
        asset.cameraModel = "OM-1"
        asset.lensModel = "12-40mm F2.8"
        asset.capturedAt = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .current,
            year: 2026, month: 7, day: 2, hour: 14, minute: 5
        ).date
        asset.gpsLatitude = 45.5
        asset.gpsLongitude = -122.6
        asset.gpsAltitude = 30

        let service = ProcessMoveService()
        let result = try await service.processAndCopy(
            asset: asset, renameContext: renameContext(for: asset), libraryRoot: libraryRoot)

        XCTAssertEqual(result.sourceURL, sourceURL)
        XCTAssertEqual(
            result.destinationURL.path,
            libraryRoot.appendingPathComponent("7 July/02/jpg/1010042_Yosemite_20260702_1405_OM-1_12-40mm-F2.8.jpg").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path), "source must never be removed")

        let client = ExifToolClient()
        let metadata = try await client.readMetadata(at: result.destinationURL)
        XCTAssertEqual(
            metadata["IPTC:ObjectName"] as? String, "1010042_Yosemite_20260702_1405_OM-1_12-40mm-F2.8")
        XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "My description")
        // docs/SPEC.md §6's auto-applied metadata rules (`AutoMetadataRules`) append camera/lens/
        // SOOC tokens at write time — see `ProcessMoveService.processAndCopy`.
        XCTAssertEqual(
            metadata["IPTC:Keywords"] as? [String], ["mountain", "sunrise", "OM-1", "12-40mm F2.8", "sooc"])
        XCTAssertEqual(metadata["GPS:GPSLatitudeRef"] as? String, "North")
    }

    func testProcessAndCopyThrowsWhenSourceIsMissing() async throws {
        let libraryRoot = try makeTempDirectory()
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).jpg")
        let asset = PhotoAsset(id: missingURL)

        let service = ProcessMoveService()
        do {
            _ = try await service.processAndCopy(
                asset: asset, renameContext: renameContext(for: asset), libraryRoot: libraryRoot)
            XCTFail("expected sourceNotFound to be thrown")
        } catch ProcessMoveError.sourceNotFound(let url) {
            XCTAssertEqual(url, missingURL)
        }
    }

    func testProcessAndCopyResolvesFilenameCollisionsInDestinationFolder() async throws {
        let sourceDirectory = try makeTempDirectory()
        let libraryRoot = try makeTempDirectory()
        let firstSourceURL = try makeSourceJPEG(named: "P1010042.JPG", in: sourceDirectory)
        let secondSourceURL = try makeSourceJPEG(named: "P1010099.JPG", in: sourceDirectory)

        let capturedAt = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .current,
            year: 2026, month: 7, day: 2, hour: 14, minute: 5
        ).date

        var firstAsset = PhotoAsset(id: firstSourceURL)
        firstAsset.capturedAt = capturedAt
        var secondAsset = PhotoAsset(id: secondSourceURL)
        secondAsset.capturedAt = capturedAt

        // Both contexts share the same `sourceURL` (deliberately `firstSourceURL` for both), so
        // `RenameService` computes the identical destination filename for each and the second
        // process-and-copy must collide with the first.
        var firstContext = renameContext(for: firstAsset)
        firstContext.sourceURL = firstSourceURL
        var secondContext = renameContext(for: secondAsset)
        secondContext.sourceURL = firstSourceURL

        let service = ProcessMoveService()
        let firstResult = try await service.processAndCopy(
            asset: firstAsset, renameContext: firstContext, libraryRoot: libraryRoot)
        let secondResult = try await service.processAndCopy(
            asset: secondAsset, renameContext: secondContext, libraryRoot: libraryRoot)

        XCTAssertNotEqual(firstResult.destinationURL, secondResult.destinationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstResult.destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondResult.destinationURL.path))
    }

    func testDestinationDirectoryRoutesJPEGUnderJpgSubfolderAndRawToBaseFolder() {
        let libraryRoot = URL(fileURLWithPath: "/library")
        let capturedAt = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .current,
            year: 2026, month: 3, day: 9
        ).date!

        var jpegAsset = PhotoAsset(id: URL(fileURLWithPath: "/card/P1010042.JPG"))
        jpegAsset.capturedAt = capturedAt
        var rawAsset = PhotoAsset(id: URL(fileURLWithPath: "/card/P1010042.ORF"))
        rawAsset.capturedAt = capturedAt

        XCTAssertEqual(
            ProcessMoveService.destinationDirectory(for: jpegAsset, libraryRoot: libraryRoot).path,
            "/library/3 March/09/jpg")
        XCTAssertEqual(
            ProcessMoveService.destinationDirectory(for: rawAsset, libraryRoot: libraryRoot).path,
            "/library/3 March/09")
    }

    func testDestinationDirectoryFallsBackToFileModificationDateWhenCapturedAtIsMissing() throws {
        let sourceDirectory = try makeTempDirectory()
        let sourceURL = try makeSourceJPEG(in: sourceDirectory)
        let knownDate = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .current,
            year: 2025, month: 11, day: 20
        ).date!
        try FileManager.default.setAttributes([.modificationDate: knownDate], ofItemAtPath: sourceURL.path)

        var asset = PhotoAsset(id: sourceURL)
        asset.capturedAt = nil

        let destination = ProcessMoveService.destinationDirectory(
            for: asset, libraryRoot: URL(fileURLWithPath: "/library"))

        XCTAssertEqual(destination.path, "/library/11 November/20/jpg")
    }
}
