import CoreImage
import Foundation

public enum RawDevelopError: Error, Equatable {
    /// `CIRAWFilter` wouldn't open the file at all — not a RAW format this OS decodes.
    case unsupportedFile(URL)
    case renderFailed(URL)
}

/// Which decoder a develop run should use, and how to reach it.
public enum RawDevelopRoute: Equatable {
    /// Decode the original file directly at this decoder version.
    case direct(decoderVersion: String)
    /// Convert to DNG first, then decode the DNG at `RawDevelopService.dngDecoderVersion`. The route
    /// for any camera the newest decoder doesn't list — which is most of them.
    case viaDNG
}

public struct RawDevelopResult: Equatable {
    public var destinationURL: URL
    /// The `CIRAWFilter` decoder version string actually used, e.g. `"9"` or `"9.dng"`.
    public var decoderVersion: String
    /// Filename/keyword token derived from `decoderVersion`, e.g. `"RAW9"`.
    public var token: String
}

/// Renders a camera RAW file to a JPEG using Apple's RAW engine, picking the newest decoder that
/// file can actually reach. See docs/SPEC.md §5 "RAW develop".
///
/// The routing exists because decoder support is per camera model, not per format. On macOS 27
/// (`RawCamera.bundle` 9.50.0) decoder 9 lists only 69 models: an OM-3 `.orf` reports
/// `["7", "8"]` and an X-T5 `.RAF` reports `["7", "8", "9"]`. Repackaging either as a DNG makes
/// `"9.dng"` available, because the DNG pipeline is model-agnostic — which is what makes
/// `.viaDNG` the general answer for an unsupported body, and what makes this need no maintenance
/// when a camera is added to the decoder-9 list: it simply starts taking `.direct` instead.
///
/// Rendering is at the filter's default settings deliberately. This is not a develop UI — the point
/// is Apple's engine applied to the file as the camera recorded it, the same thing Preview or Photos
/// would show.
public struct RawDevelopService {
    /// Decoder version reachable only through a DNG. The `.dng` suffix is `CIRAWFilter`'s own
    /// spelling, not a file extension.
    static let dngDecoderVersion = "9.dng"
    private static let newestDecoderVersion = "9"
    private static let compressionQuality: CGFloat = 0.95

    private let dngConverter: (any DNGConverting)?

    /// `dngConverter` is optional because iPad has no converter to give it — there, a body outside
    /// the decoder-9 list falls back to the newest decoder the file itself offers rather than
    /// failing.
    public init(dngConverter: (any DNGConverting)? = nil) {
        self.dngConverter = dngConverter
    }

    public func develop(_ source: URL, to destination: URL) async throws -> RawDevelopResult {
        guard let filter = CIRAWFilter(imageURL: source) else {
            throw RawDevelopError.unsupportedFile(source)
        }

        // The initialiser above is not a gate: `CIRAWFilter(imageURL:)` returns a filter for any
        // readable file, including a text file, and only then reports `["None"]` as its decoder
        // list with a zero `nativeSize`. Screening for a real, numbered decoder is what actually
        // says "this is a RAW this OS can develop" — and it keeps the sentinel out of `route`,
        // which would otherwise take it for a version and render at "None".
        let supported = filter.supportedDecoderVersions.map(\.rawValue).filter { Self.major(of: $0) > 0 }
        guard !supported.isEmpty else { throw RawDevelopError.unsupportedFile(source) }

        switch Self.route(supportedVersions: supported, hasDNGConverter: dngConverter != nil) {
        case .direct(let version):
            try render(filter, at: version, from: source, to: destination)
            return Self.result(destination: destination, decoderVersion: version)
        case .viaDNG:
            let version = try await developViaDNG(
                source, to: destination, baselineExposure: filter.baselineExposure)
            return Self.result(destination: destination, decoderVersion: version)
        }
    }

    /// Converts into a unique subdirectory of the system temp directory, renders from there, and
    /// removes the whole directory afterwards. `removeItem` rather than `trashItem` here is a
    /// deliberate exception to CLAUDE.md "File Safety": this is app-created scratch that never held
    /// user data, and a ~20MB intermediate DNG per developed frame accumulating in the Trash would
    /// be worse than useless.
    ///
    /// `baselineExposure` is carried over from the original file because the converter substitutes
    /// its own, and Apple's decoder honours whatever the DNG says. Measured on the three sample
    /// files: the OM-3 (0.50) and X-T5 (0.10) come through the conversion unchanged, but the X-E4's
    /// +1.02 — Fuji's ISO offset, which their raw data needs lifting by — is rewritten to -0.70,
    /// rendering about 1.7 stops dark (mean luminance 0.489 direct, 0.227 via DNG, against an
    /// embedded camera preview of 0.489). Restoring the original value puts it back at 0.489 and
    /// leaves the other two bit-identical, since for them it is the value already there.
    private func developViaDNG(_ source: URL, to destination: URL, baselineExposure: Float)
        async throws -> String
    {
        guard let dngConverter else { throw RawDevelopError.unsupportedFile(source) }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawDevelop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let dngURL = try await dngConverter.convertToDNG(source, outputDirectory: scratch)
        guard let dngFilter = CIRAWFilter(imageURL: dngURL) else {
            throw RawDevelopError.unsupportedFile(dngURL)
        }
        dngFilter.baselineExposure = baselineExposure
        try render(dngFilter, at: Self.dngDecoderVersion, from: dngURL, to: destination)
        return Self.dngDecoderVersion
    }

    /// `decoderVersion` is always set explicitly, never left at the filter's default. Apple documents
    /// the default as "the newest available decoder version for the given image type", but an X-T5
    /// `.RAF` that lists `9` as supported still opens at `8` — trusting the default would silently
    /// ship a decoder-8 render from the one camera that doesn't need the DNG detour.
    ///
    /// Output carries the EXIF the filter read from the RAW (capture time, camera, lens, exposure)
    /// with no extra work, which is what lets a derivative land in its original's capture set. The
    /// filter also bakes the camera's rotation into the pixels and leaves the orientation tag
    /// neutral, so there is no orientation to correct here.
    private func render(_ filter: CIRAWFilter, at version: String, from source: URL, to destination: URL)
        throws
    {
        filter.decoderVersion = type(of: filter.decoderVersion).init(rawValue: version)
        guard let image = filter.outputImage else { throw RawDevelopError.renderFailed(source) }

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        do {
            try CIContext().writeJPEGRepresentation(
                of: image, to: destination, colorSpace: colorSpace,
                options: [
                    kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                        Self.compressionQuality
                ])
        } catch {
            throw RawDevelopError.renderFailed(source)
        }
    }

    private static func result(destination: URL, decoderVersion: String) -> RawDevelopResult {
        RawDevelopResult(
            destinationURL: destination, decoderVersion: decoderVersion,
            token: token(forDecoderVersion: decoderVersion))
    }

    /// Pure, so the routing can be tested without a RAW file on disk — see `RawDevelopServiceTests`.
    public static func route(supportedVersions: [String], hasDNGConverter: Bool) -> RawDevelopRoute {
        if supportedVersions.contains(newestDecoderVersion) {
            return .direct(decoderVersion: newestDecoderVersion)
        }
        if hasDNGConverter {
            return .viaDNG
        }
        return .direct(decoderVersion: newest(of: supportedVersions) ?? newestDecoderVersion)
    }

    /// Highest major version, preferring the `.dng` variant on a tie — on a DNG input those are the
    /// native decoders rather than the compatibility ones.
    private static func newest(of versions: [String]) -> String? {
        versions.max { left, right in
            (major(of: left), left.hasSuffix(".dng") ? 1 : 0)
                < (major(of: right), right.hasSuffix(".dng") ? 1 : 0)
        }
    }

    private static func major(of version: String) -> Int {
        Int(version.prefix { $0.isNumber }) ?? 0
    }

    /// `"9.dng"` and `"9"` are the same engine reached two ways, so both report `RAW9` — the token
    /// records which decoder rendered the file, not how it was fed. Deriving it from the version
    /// string rather than hardcoding means RAW 10 needs no change here.
    public static func token(forDecoderVersion version: String) -> String {
        "RAW\(major(of: version))"
    }

    /// Keyword the iPad writes into a staged sidecar to say "this RAW needs developing, but I can't
    /// do it" — iPadOS has no way to produce a DNG (`CGImageDestinationCopyTypeIdentifiers()` lists
    /// none) and no camera outside the decoder-9 list can be developed without one.
    ///
    /// It travels as an ordinary keyword because that channel already exists end to end: staged
    /// sidecar, Process & Move, the destination copy's `.xmp`, and finally `IPadImportService` on
    /// the Mac, which acts on it and strips it before anything is written into the library. The
    /// `MPM-` prefix marks it as this app's bookkeeping rather than one of the user's own keywords.
    public static let developMarkerKeyword = "MPM-DevelopRAW"

    public static func isMarkedForDevelop(_ keywords: [String]) -> Bool {
        keywords.contains { $0.caseInsensitiveCompare(developMarkerKeyword) == .orderedSame }
    }

    public static func removingDevelopMarker(from keywords: [String]) -> [String] {
        keywords.filter { $0.caseInsensitiveCompare(developMarkerKeyword) != .orderedSame }
    }

    /// Recovers the token a develop run wrote into the derivative's keywords, for the filename's
    /// art-filter slot at process time.
    ///
    /// The keywords are where it lives because a staged derivative outlives the session that made
    /// it: asking the file which decoder rendered it would otherwise mean decoding the RAW a second
    /// time just to find out. Matching by shape rather than against a list of known versions means
    /// a `RAW10` written by a future release still reads back here.
    public static func token(in keywords: [String]) -> String? {
        keywords.first { keyword in
            let upper = keyword.uppercased()
            guard upper.hasPrefix("RAW") else { return false }
            let digits = upper.dropFirst(3)
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }?.uppercased()
    }
}
