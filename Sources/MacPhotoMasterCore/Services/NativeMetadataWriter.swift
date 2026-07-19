import CoreGraphics
import Foundation
import ImageIO

public enum NativeMetadataWriteError: Error {
    case xmpSerializationFailed
}

/// Writes metadata to a standalone XMP sidecar next to the photo instead of into the photo
/// itself. Two findings from prototyping against real OM System files (see the ImageIO
/// write-back spike) ruled out writing directly, even for JPEG:
///
/// - RAW formats (e.g. `.orf`) have no registered `CGImageDestination` UTI at all — ImageIO can
///   decode them but there's no encoder to write back into.
/// - Even for JPEG, `CGImageDestinationCopyImageSource`'s metadata parameter fully replaces the
///   image's `CGImageMetadata` rather than merging into it, and MakerNotes (Olympus/OM System
///   `ArtFilterEffect`, `FocusDistance`, `SerialNumber`, etc.) have no representation in that
///   model at all — confirmed empirically: writing this way drops ~150 MakerNotes tags regardless
///   of whether the write starts from a blank metadata object or a mutable copy of the original's.
///
/// So this never touches the original file's bytes, on any format. `ExifToolClient
/// .foldInSidecarIfPresent(for:)` is the other half: once a file reaches a Mac (where `exiftool`
/// is available and is MakerNotes-aware), it folds this sidecar's fields into the original via the
/// same write path a direct Mac-side save uses, then deletes the sidecar.
///
/// GPS quirk confirmed against a real sidecar round-trip: XMP-namespace GPS tags encode
/// hemisphere via the value's *sign*, not a separate Ref tag the way legacy EXIF/TIFF IFD GPS
/// does — writing a positive longitude plus a `GPSLongitudeRef=W` tag still reads back as East
/// (exiftool ignores the XMP Ref tag). So this writes signed decimal degrees only, no Ref tags.
public struct NativeMetadataWriter: MetadataWriter {
    public func write(title: String?, description: String, keywords: [String], gps: GPSCoordinate?, to url: URL)
        async throws
    {
        try MetadataWriteFieldRules.validate(gps: gps)
        let data = try Self.xmpData(title: title, description: description, keywords: keywords, gps: gps)
        try data.write(to: Self.sidecarURL(for: url), options: .atomic)
    }

    public func write(description: String, keywords: [String], gps: GPSCoordinate?, to urls: [URL]) async throws
        -> [URL: Result<Void, Error>]
    {
        try MetadataWriteFieldRules.validate(gps: gps)
        var results: [URL: Result<Void, Error>] = [:]
        for url in urls {
            do {
                try await write(title: nil, description: description, keywords: keywords, gps: gps, to: url)
                results[url] = .success(())
            } catch {
                results[url] = .failure(error)
            }
        }
        return results
    }

    /// Sidecar filename convention `ExifToolClient.foldInSidecarIfPresent(for:)` also uses: same
    /// basename, `.xmp` extension.
    public static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }

    private static func xmpData(
        title: String?, description: String, keywords: [String], gps: GPSCoordinate?
    ) throws -> Data {
        let metadata = CGImageMetadataCreateMutable()

        if let title, !title.isEmpty {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName,
                title as CFString)
        }
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract,
            description as CFString)
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords,
            MetadataWriteFieldRules.normalizedKeywords(keywords) as CFArray)

        if let gps {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude,
                gps.latitude as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude,
                gps.longitude as CFNumber)
            if let altitude = gps.altitude {
                CGImageMetadataSetValueMatchingImageProperty(
                    metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitude,
                    altitude as CFNumber)
            }
        }

        guard let xmpData = CGImageMetadataCreateXMPData(metadata, nil) else {
            throw NativeMetadataWriteError.xmpSerializationFailed
        }
        return xmpData as Data
    }
}
