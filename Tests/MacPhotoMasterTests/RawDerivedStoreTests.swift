import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacPhotoMasterCore

final class RawDerivedStoreTests: XCTestCase {
    /// A real 1x1 JPEG, optionally padded past the EOI marker (ImageIO ignores trailing bytes) so
    /// two files can share a name but differ in size — the case the store's key ordering exists for.
    /// Same approach as `SidecarStagingStoreTests`.
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

    /// Stands in for a camera RAW: the store only ever reads the original's name and size, never its
    /// contents, so the bytes don't have to be a real ORF.
    private func makeOriginal(named name: String, sizeBump: Int = 0) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try writeBlankJPEG(to: url, sizeBump: sizeBump)
        return url
    }

    private func makeStore() throws -> RawDerivedStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try RawDerivedStore(stagingDirectory: directory)
    }

    func testNoDerivativeUntilOneIsWritten() throws {
        let original = try makeOriginal(named: "P1010042.ORF")
        let store = try makeStore()

        XCTAssertFalse(try store.hasDerivative(for: original))
        XCTAssertTrue(store.derivedAssets(forOriginals: [PhotoAsset(id: original)]).isEmpty)
    }

    /// Two cards, same camera filename, different frames. If the key collapsed them, developing one
    /// would silently hand back the other's render.
    func testTwoOriginalsWithTheSameNameButDifferentSizesGetDifferentDerivatives() throws {
        let first = try makeOriginal(named: "P1010042.ORF")
        let second = try makeOriginal(named: "P1010042.ORF", sizeBump: 4096)
        let store = try makeStore()

        XCTAssertNotEqual(try store.derivedURL(for: first), try store.derivedURL(for: second))

        try writeBlankJPEG(to: try store.derivedURL(for: first))

        XCTAssertTrue(try store.hasDerivative(for: first))
        XCTAssertFalse(try store.hasDerivative(for: second))
    }

    /// The derived name keeps the original's full name, extension included, so the staging directory
    /// reads plainly and a `.ORF`/`.JPG` pair of the same size can't collide.
    func testDerivedURLKeepsTheOriginalNameAndAddsAJPEGExtension() throws {
        let original = try makeOriginal(named: "P1010042.ORF")
        let store = try makeStore()

        let derived = try store.derivedURL(for: original)
        let size = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: original.path)[.size] as? NSNumber)?.intValue)

        XCTAssertEqual(derived.lastPathComponent, "\(size)_P1010042.ORF.jpg")
    }

    func testDerivedAssetsReadsBackTheStagedJPEGAndPointsAtItsOriginal() throws {
        let original = try makeOriginal(named: "P1010042.ORF")
        let store = try makeStore()
        let derivedURL = try store.derivedURL(for: original)
        try writeBlankJPEG(to: derivedURL)

        let assets = store.derivedAssets(forOriginals: [PhotoAsset(id: original)])

        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?.url, derivedURL)
        XCTAssertEqual(assets.first?.derivedFrom, original)
    }

    /// Originals with nothing staged are skipped rather than yielding a placeholder, so the caller
    /// can hand it a whole folder's worth of RAW files.
    func testDerivedAssetsSkipsOriginalsWithNothingStaged() throws {
        let developed = try makeOriginal(named: "P1010042.ORF")
        let untouched = try makeOriginal(named: "P1010043.ORF")
        let store = try makeStore()
        try writeBlankJPEG(to: try store.derivedURL(for: developed))

        let assets = store.derivedAssets(
            forOriginals: [PhotoAsset(id: developed), PhotoAsset(id: untouched)])

        XCTAssertEqual(assets.map(\.derivedFrom), [developed])
    }

    func testDiscardRemovesTheDerivativeAndToleratesThereBeingNone() throws {
        let original = try makeOriginal(named: "P1010042.ORF")
        let store = try makeStore()
        try writeBlankJPEG(to: try store.derivedURL(for: original))

        try store.discard(for: original)
        XCTAssertFalse(try store.hasDerivative(for: original))

        // Discarding again is what happens when a set is processed twice; it must not throw.
        try store.discard(for: original)
    }
}
