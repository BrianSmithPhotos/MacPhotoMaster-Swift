import CoreGraphics
import Foundation
import ImageIO

/// Fields read back out of a staged sidecar — the counterpart to what `NativeMetadataWriter.write`
/// takes in, minus the `to:` URL. `nil` title mirrors the writer's own "don't write an empty tag"
/// convention (see `NativeMetadataWriter.xmpData`).
public struct StagedMetadataDraft: Equatable {
    public var title: String?
    public var description: String
    public var keywords: [String]
    public var gps: GPSCoordinate?

    public init(title: String?, description: String, keywords: [String], gps: GPSCoordinate?) {
        self.title = title
        self.description = description
        self.keywords = keywords
        self.gps = gps
    }
}

public enum SidecarStagingError: Error {
    case unreadableStagedSidecar
}

/// Stages `NativeMetadataWriter` sidecars in app-local storage instead of "next to" the original
/// file, and reads them back — the iPad-only half of the write path described in
/// docs/ARCHITECTURE.md's "iPad file access & sidecar staging". A staged sidecar is keyed by the
/// original file's name + size, not its path: an SD card/camera volume that isn't reformatted
/// between review sessions can have its DCIM folder numbering roll over, so path isn't stable
/// across sessions the way it is on the Mac app's local-disk workflow, and filename+size is already
/// what distinguishes one shot from another on a card that hasn't been reformatted.
///
/// Read-back can't go through `ExifToolClient` the way `NativeMetadataWriterTests` verifies writes
/// (`exiftool` isn't available in the iOS/iPadOS sandbox — see docs/ARCHITECTURE.md), so this parses
/// the sidecar's raw XMP bytes directly via `CGImageMetadataCreateFromXMPData`.
///
/// Deliberately reads by explicit XMP path (`dc:title`, `exif:GPSLatitude`, etc.) rather than
/// `CGImageMetadataCopyTagMatchingImageProperty`, the API `NativeMetadataWriter.xmpData` uses on the
/// write side: confirmed empirically (dumping the re-parsed tag tree) that "matching image
/// property" lookups don't reliably re-match tags on a `CGImageMetadataCreateFromXMPData` object the
/// way they do on one read straight off a decoded image — every field silently came back
/// nil/empty, not just the previously-known `dc:description` gap `NativeMetadataReader` documents.
/// `dc:title`/`dc:description` also round-trip as XMP lang-alt structures (an `x-default`-tagged
/// single-element array, not a plain string), which is what `CGImageMetadataCopyStringValueWithPath`
/// is for. GPS values round-trip with double-to-text precision noise at the ~1e-14 level (e.g.
/// -122.6 comes back -122.59999999999999) — irrelevant at real GPS accuracy, not corrected here.
public struct SidecarStagingStore {
    private let stagingDirectory: URL

    /// `stagingDirectory` is created if it doesn't exist yet.
    public init(stagingDirectory: URL) throws {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        self.stagingDirectory = stagingDirectory
    }

    /// Application Support location shared across app launches — same base directory
    /// `SkipStateStore`/`AppSupportDirectory` use for other local-only state.
    public static func makeDefault() throws -> SidecarStagingStore {
        let directory = try AppSupportDirectory.url(forFileNamed: "SidecarStaging")
        return try SidecarStagingStore(stagingDirectory: directory)
    }

    /// Writes (or overwrites) the staged sidecar for `assetURL`. Delegates the actual XMP
    /// serialization to `NativeMetadataWriter` by handing it a synthetic URL inside the staging
    /// directory whose basename is this asset's staging key — `NativeMetadataWriter` never reads
    /// from the URL it's given, only derives a sidecar path from it, so this reuses its exact
    /// tested write path without duplicating any XMP-building logic.
    public func stage(
        title: String?, description: String, keywords: [String], gps: GPSCoordinate?, for assetURL: URL
    ) async throws {
        let key = try Self.stagingKey(for: assetURL)
        let syntheticURL = stagingDirectory.appendingPathComponent(key)
        try await NativeMetadataWriter().write(
            title: title, description: description, keywords: keywords, gps: gps, to: syntheticURL)
    }

    /// The previously staged draft for `assetURL`, or `nil` if nothing's been staged yet.
    public func stagedDraft(for assetURL: URL) throws -> StagedMetadataDraft? {
        let sidecarURL = try stagedSidecarURL(for: assetURL)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return nil }
        let data = try Data(contentsOf: sidecarURL)
        return try Self.parseDraft(from: data)
    }

    public func hasStagedDraft(for assetURL: URL) throws -> Bool {
        FileManager.default.fileExists(atPath: try stagedSidecarURL(for: assetURL).path)
    }

    private func stagedSidecarURL(for assetURL: URL) throws -> URL {
        let key = try Self.stagingKey(for: assetURL)
        return NativeMetadataWriter.sidecarURL(for: stagingDirectory.appendingPathComponent(key))
    }

    /// `<size>_<filename>`, size first — keeping the camera-original filename (rather than e.g.
    /// hashing it) makes a staging directory listing readable for debugging, and camera filenames
    /// are already filesystem-safe by construction. Size has to come *before* the filename, not
    /// after: `NativeMetadataWriter.sidecarURL(for:)` derives the sidecar name via
    /// `deletingPathExtension()`, which treats everything after the last `.` as the extension —
    /// `"P1234567.JPG_706"` and `"P1234567.JPG_4802"` both collapse to base `"P1234567"` regardless
    /// of size (confirmed the hard way: two different-size same-name fixtures collided in
    /// `SidecarStagingStoreTests` until this ordering was fixed). Putting the size first keeps the
    /// real `.JPG`/`.ORF` extension as the only thing `deletingPathExtension()` ever strips.
    private static func stagingKey(for assetURL: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: assetURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return "\(size)_\(assetURL.lastPathComponent)"
    }

    private static func parseDraft(from xmpData: Data) throws -> StagedMetadataDraft {
        guard let metadata = CGImageMetadataCreateFromXMPData(xmpData as CFData) else {
            throw SidecarStagingError.unreadableStagedSidecar
        }

        let title = langAltString(metadata, "dc:title")
        let description = langAltString(metadata, "dc:description") ?? ""
        let keywords = stringBag(metadata, "dc:subject")

        var gps: GPSCoordinate?
        if let latitude = numberValue(metadata, "exif:GPSLatitude"),
            let longitude = numberValue(metadata, "exif:GPSLongitude")
        {
            gps = GPSCoordinate(latitude: latitude, longitude: longitude, altitude: numberValue(metadata, "exif:GPSAltitude"))
        }

        return StagedMetadataDraft(
            title: title?.isEmpty == false ? title : nil, description: description, keywords: keywords, gps: gps)
    }

    /// `dc:title`/`dc:description` are lang-alt structures (one entry per language, tagged
    /// `x-default` here since `NativeMetadataWriter` never sets a language) — this API is the one
    /// ImageIO provides for reading a scalar value back out of that structure.
    private static func langAltString(_ metadata: CGImageMetadata, _ path: String) -> String? {
        CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }

    /// `dc:subject` is an unordered bag of plain string tags — unlike the lang-alt fields, its
    /// value is a list of child tags rather than a scalar, so each needs its own
    /// `CGImageMetadataTagCopyValue` call.
    private static func stringBag(_ metadata: CGImageMetadata, _ path: String) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
            let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag]
        else { return [] }
        return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    private static func numberValue(_ metadata: CGImageMetadata, _ path: String) -> Double? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
            let value = CGImageMetadataTagCopyValue(tag)
        else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
