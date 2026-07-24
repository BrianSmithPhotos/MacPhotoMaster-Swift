import CoreGraphics
import Foundation
import ImageIO

/// Reads a `NativeMetadataWriter` XMP sidecar back into a `StagedMetadataDraft`.
///
/// Split out of `SidecarStagingStore` (which keys sidecars by filename+size inside an app-local
/// staging directory) because the Mac app's iPad import needs the same parse against a sidecar
/// sitting plainly beside its image, with no staging key involved. Reading the XMP directly rather
/// than via `ExifToolClient` saves a process launch per file and recovers altitude, which
/// `ExifToolClient.foldInSidecarIfPresent` doesn't ask for.
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
public enum SidecarDraftParsing {
    /// The draft in the sidecar at `sidecarURL`, or `nil` if there's no file there. Throws
    /// `SidecarStagingError.unreadableStagedSidecar` if the file exists but isn't parseable XMP —
    /// callers distinguish the two, since a corrupt sidecar is worth reporting where a missing one
    /// may just mean nothing was ever staged.
    public static func draft(at sidecarURL: URL) throws -> StagedMetadataDraft? {
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return nil }
        return try draft(fromXMPData: try Data(contentsOf: sidecarURL))
    }

    public static func draft(fromXMPData xmpData: Data) throws -> StagedMetadataDraft {
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
            gps = GPSCoordinate(
                latitude: latitude, longitude: longitude, altitude: numberValue(metadata, "exif:GPSAltitude"))
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
