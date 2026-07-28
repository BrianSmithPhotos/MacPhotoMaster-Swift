import AppKit
import CoreImage
import ImageIO
import XCTest

@testable import MacPhotoMasterCore

/// Records whether it was reached and then fails, which is all the routing tests need: the point is
/// that branch 2 hands off to a converter at all, not that this one produces a usable DNG.
private final class SpyDNGConverter: DNGConverting, @unchecked Sendable {
    private(set) var callCount = 0

    struct Refused: Error {}

    func convertToDNG(_ source: URL, outputDirectory: URL) async throws -> URL {
        callCount += 1
        throw Refused()
    }
}

/// Shells out to Adobe DNG Converter the same way the app target's `AdobeDNGConverter` does. The
/// real one lives in the app target and so can't be imported here; this is only the invocation, with
/// none of its timeout or stderr handling, because the one test using it just needs a genuine DNG on
/// disk to prove the render against.
private struct RealDNGConverter: DNGConverting {
    let executableURL: URL

    init?() {
        guard
            let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.adobe.DNGConverter"),
            let executableURL = Bundle(url: appURL)?.executableURL
        else { return nil }
        self.executableURL = executableURL
    }

    func convertToDNG(_ source: URL, outputDirectory: URL) async throws -> URL {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-c", "-p0", "-d", outputDirectory.path, source.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return outputDirectory
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("dng")
    }
}

final class RawDevelopServiceTests: XCTestCase {
    /// `samples/` holds real camera files and is gitignored (118MB, public repo), so every test that
    /// needs one skips when it isn't there. The routing tests below deliberately need none.
    private func sampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("samples")
            .appendingPathComponent(name)
    }

    private func temporaryJPEGURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RawDevelopServiceTests-\(UUID().uuidString).jpg")
    }

    // MARK: - Routing

    /// Branch 1: a body on the decoder-9 list is decoded straight, converter or not. This is the
    /// path OM System files are expected to take once those bodies join the list at release.
    func testRouteDecodesDirectlyWhenTheFileItselfSupportsDecoderNine() {
        for hasConverter in [true, false] {
            XCTAssertEqual(
                RawDevelopService.route(
                    supportedVersions: ["7", "8", "9"], hasDNGConverter: hasConverter),
                .direct(decoderVersion: "9"))
        }
    }

    /// Branch 2: the general answer for an unsupported body.
    func testRouteGoesViaDNGWhenDecoderNineIsOutOfReachAndAConverterExists() {
        XCTAssertEqual(
            RawDevelopService.route(supportedVersions: ["7", "8"], hasDNGConverter: true), .viaDNG)
    }

    /// Branch 3: iPad, or a Mac with no DNG Converter installed. Falls back rather than failing.
    func testRouteFallsBackToTheNewestAvailableVersionWithNoConverter() {
        XCTAssertEqual(
            RawDevelopService.route(supportedVersions: ["7", "8"], hasDNGConverter: false),
            .direct(decoderVersion: "8"))
    }

    /// A DNG's own version list interleaves plain and `.dng` spellings; the `.dng` ones are its
    /// native decoders, so a tie on major version must resolve to those.
    func testRoutePrefersTheDNGSpellingOnATieInMajorVersion() {
        XCTAssertEqual(
            RawDevelopService.route(
                supportedVersions: ["6.dng", "7", "7.dng", "8", "8.dng"], hasDNGConverter: false),
            .direct(decoderVersion: "8.dng"))
    }

    /// Both spellings are the same engine reached two ways, so both report the same token — what it
    /// records is which decoder rendered the file, not how the file was fed to it.
    func testTokenReportsTheMajorVersionForBothSpellings() {
        XCTAssertEqual(RawDevelopService.token(forDecoderVersion: "9"), "RAW9")
        XCTAssertEqual(RawDevelopService.token(forDecoderVersion: "9.dng"), "RAW9")
        XCTAssertEqual(RawDevelopService.token(forDecoderVersion: "8"), "RAW8")
    }

    /// Read back off the derivative at process time. Matched by shape, so a future `RAW10` survives
    /// a round trip through the file's keywords without a code change.
    func testTokenIsRecoveredFromKeywordsAndIgnoresEverythingElse() {
        XCTAssertEqual(RawDevelopService.token(in: ["heron", "RAW9", "OM-3"]), "RAW9")
        XCTAssertEqual(RawDevelopService.token(in: ["raw10"]), "RAW10")
        XCTAssertNil(RawDevelopService.token(in: ["heron", "OM-3", "sooc"]))
        // Near misses that must not be mistaken for a decoder token.
        XCTAssertNil(RawDevelopService.token(in: ["RAW"]))
        XCTAssertNil(RawDevelopService.token(in: ["RAW9x"]))
    }

    // MARK: - iPad develop marker

    /// Case-insensitive both ways: the marker makes a round trip through an XMP sidecar and
    /// `exiftool`, neither of which is guaranteed to hand the keyword back with its original casing.
    func testDevelopMarkerIsRecognisedAndStrippedRegardlessOfCase() {
        XCTAssertTrue(RawDevelopService.isMarkedForDevelop(["heron", "mpm-developraw"]))
        XCTAssertFalse(RawDevelopService.isMarkedForDevelop(["heron", "MPM-DevelopRAW-later"]))

        XCTAssertEqual(
            RawDevelopService.removingDevelopMarker(from: ["heron", "MPM-DEVELOPRAW", "OM-3"]),
            ["heron", "OM-3"])
    }

    /// The marker must never reach a library copy's keywords — it is this app's bookkeeping, and
    /// `IPadImportService` strips it whether or not it acts on it.
    func testRemovingTheDevelopMarkerLeavesEveryOtherKeywordAlone() {
        let keywords = ["heron", "Point Reyes", "RAW9"]

        XCTAssertEqual(RawDevelopService.removingDevelopMarker(from: keywords), keywords)
    }

    // MARK: - Dispatch

    /// `CIRAWFilter(imageURL:)` returns a filter for this file rather than nil — it reports
    /// `["None"]` as its decoder list and a zero `nativeSize` instead. Without the screen in
    /// `develop`, that sentinel would be routed to as if it were a version.
    func testDevelopRejectsAFileWithNoRealDecoder() async throws {
        let notRaw = temporaryJPEGURL()
        try Data("not a raw file".utf8).write(to: notRaw)
        defer { try? FileManager.default.removeItem(at: notRaw) }

        do {
            _ = try await RawDevelopService().develop(notRaw, to: temporaryJPEGURL())
            XCTFail("Expected unsupportedFile")
        } catch {
            XCTAssertEqual(error as? RawDevelopError, .unsupportedFile(notRaw))
        }
    }

    /// Proves the branch choice against a real file rather than a hand-written version list: the
    /// OM-3 is not on the decoder-9 list, so a converter must be reached for.
    func testDevelopReachesForTheConverterOnACameraDecoderNineDoesNotList() async throws {
        let source = sampleURL("1066411_SanRafael_20260727_0929_OM-3_OM-100-400mm-F5.0-6.3-II.orf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))

        let converter = SpyDNGConverter()
        do {
            _ = try await RawDevelopService(dngConverter: converter)
                .develop(source, to: temporaryJPEGURL())
            XCTFail("Expected the stub converter's error to propagate")
        } catch is SpyDNGConverter.Refused {
            XCTAssertEqual(converter.callCount, 1)
        }
    }

    /// The same file with no converter takes branch 3 and really renders, at v8.
    func testDevelopRendersAtTheNewestAvailableDecoderWithNoConverter() async throws {
        let source = sampleURL("1066411_SanRafael_20260727_0929_OM-3_OM-100-400mm-F5.0-6.3-II.orf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))

        let destination = temporaryJPEGURL()
        defer { try? FileManager.default.removeItem(at: destination) }

        let result = try await RawDevelopService().develop(source, to: destination)

        XCTAssertEqual(result.decoderVersion, "8")
        XCTAssertEqual(result.token, "RAW8")
        XCTAssertEqual(result.destinationURL, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    /// The X-T5 is on the decoder-9 list, so it renders direct at v9 and never touches the
    /// converter. Also the one place the "always set `decoderVersion` explicitly" rule is
    /// observable: this file reports 9 as supported but opens at 8, so a service trusting
    /// `CIRAWFilter`'s default would report `RAW8` here.
    func testDevelopRendersDirectlyAtDecoderNineForASupportedCamera() async throws {
        let source = sampleURL("DSCF5072.RAF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))

        let destination = temporaryJPEGURL()
        defer { try? FileManager.default.removeItem(at: destination) }
        let converter = SpyDNGConverter()

        let result = try await RawDevelopService(dngConverter: converter)
            .develop(source, to: destination)

        XCTAssertEqual(result.decoderVersion, "9")
        XCTAssertEqual(result.token, "RAW9")
        XCTAssertEqual(converter.callCount, 0)

        // The metadata the derivative needs to join its original's capture set, plus the proof that
        // rotation is baked into the pixels rather than left to the orientation tag.
        let source_ = CGImageSourceCreateWithURL(destination as CFURL, nil)
        let properties = CGImageSourceCopyPropertiesAtIndex(source_!, 0, nil) as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        XCTAssertEqual(properties?[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 5152)
        XCTAssertEqual(properties?[kCGImagePropertyPixelHeight] as? Int, 7728)
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "X-T5")
        XCTAssertNotNil(exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
    }

    /// The DNG detour must not change the exposure. Adobe's converter writes its own
    /// `BaselineExposure`, and on this X-E4 file it replaces Fuji's +1.02 with -0.70, which rendered
    /// the derivative about 1.7 stops darker than the camera's own preview until `developViaDNG`
    /// started carrying the original's value over. Compares the via-DNG render against the same
    /// file's direct render, so it asserts a relationship rather than a magic brightness number.
    ///
    /// Needs both the sample and Adobe DNG Converter installed, and takes a few seconds.
    func testDevelopViaDNGMatchesTheDirectRenderExposure() async throws {
        let source = sampleURL(
            "May 17, 2022-untitled-1324-09-11-Fujifilm-X-E4-XF27mmF2.8 R WR-"
                + "Angels_Palace_Kodachrome-May 17 2022-1324.RAF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))
        let converter = try XCTUnwrap(RealDNGConverter(), "Adobe DNG Converter not installed")

        let direct = temporaryJPEGURL()
        let viaDNG = temporaryJPEGURL()
        defer {
            try? FileManager.default.removeItem(at: direct)
            try? FileManager.default.removeItem(at: viaDNG)
        }

        let directResult = try await RawDevelopService().develop(source, to: direct)
        let dngResult = try await RawDevelopService(dngConverter: converter)
            .develop(source, to: viaDNG)

        XCTAssertEqual(directResult.decoderVersion, "8")
        XCTAssertEqual(dngResult.decoderVersion, "9.dng")
        // 5% of full scale: comfortably tighter than the 0.49 -> 0.23 the bug produced, and loose
        // enough for the two decoders' genuinely different tone rendering.
        XCTAssertEqual(try meanLuminance(of: direct), try meanLuminance(of: viaDNG), accuracy: 0.05)
    }

    /// Mean of the whole frame via `CIAreaAverage`, 0...1 — enough to catch a whole-image exposure
    /// shift, which is the only thing the test above is looking for.
    private func meanLuminance(of url: URL) throws -> Double {
        let image = try XCTUnwrap(CIImage(contentsOf: url))
        let average = CIFilter(name: "CIAreaAverage")!
        average.setValue(image, forKey: kCIInputImageKey)
        average.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            try XCTUnwrap(average.outputImage), toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2]))
            / 255
    }
}
