import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class PhotoAssetLoaderTests: XCTestCase {
    /// Same synthesis approach as `NativeMetadataReaderTests` — a real, tiny in-memory JPEG so
    /// this test needs no external fixture.
    private func writeSampleJPEG(to url: URL) throws {
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

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw NativeMetadataError.unreadableFile
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testLoadAssetsSkipsUnsupportedExtensionsAndUnreadableFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeSampleJPEG(to: folder.appendingPathComponent("real.jpg"))
        // Not a real JPEG despite the extension — exercises the "skip, don't fail the batch" path.
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("corrupt.jpg"))
        // Unsupported extension — must be filtered out before any read is attempted.
        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let assets = try await PhotoAssetLoader().loadAssets(in: folder)

        XCTAssertEqual(assets.map(\.url.lastPathComponent), ["real.jpg"])
    }

    func testLoadAssetsReturnsEmptyArrayForFolderWithNoSupportedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let assets = try await PhotoAssetLoader().loadAssets(in: folder)

        XCTAssertTrue(assets.isEmpty)
    }

    func testLoadAssetsReadsEveryFileWhenCountExceedsTheConcurrencyCap() async throws {
        // Deliberately more files than any plausible core count, to exercise the "refill the
        // queue as a child task finishes" bookkeeping in readAssets(at:) rather than just the
        // initial batch of concurrent reads.
        let fileCount = ProcessInfo.processInfo.activeProcessorCount * 3 + 5
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var expectedNames: Set<String> = []
        for index in 0..<fileCount {
            let name = String(format: "photo-%03d.jpg", index)
            try writeSampleJPEG(to: folder.appendingPathComponent(name))
            expectedNames.insert(name)
        }

        let assets = try await PhotoAssetLoader().loadAssets(in: folder)

        XCTAssertEqual(assets.count, fileCount)
        XCTAssertEqual(Set(assets.map(\.url.lastPathComponent)), expectedNames)
    }
}
