import CoreGraphics
import Foundation
import ImageIO

enum NativeMetadataError: Error {
    case unreadableFile
}

/// Reads EXIF/IPTC/GPS metadata directly via ImageIO — no `exiftool` subprocess, no
/// process-launch cost, and none of the PATH-resolution issues documented in
/// docs/ARCHITECTURE.md's "Resolving the exiftool binary" section. ImageIO also hands back
/// already-decimal GPS/aperture/exposure values instead of exiftool's raw DMS/fraction strings,
/// so there's no coordinate-parsing logic to port from the reference app's `_parse_dms_coordinate`.
///
/// Scope note: this does not reach manufacturer maker-note fields (Olympus's
/// ArtFilterEffect/PictureMode/StackedImage/FocusDistance tags used for the reference app's
/// art-filter detection and this app's Focus Distance display — see docs/SPEC.md §2). ImageIO only
/// exposes maker-note dictionaries it has a built-in decoder for, and Olympus's proprietary tags
/// aren't among them; `exiftool` remains the
/// only reliable source for those, so this reader is a prototype for the *standard* EXIF/IPTC/GPS
/// field set, not a full `ExifToolClient` replacement yet.
///
/// Second known gap, confirmed against a real OM SYSTEM camera JPEG (not reproducible with a bare
/// synthetic fixture): ImageIO can fail to read back `Caption-Abstract`/description on these files
/// even when the on-disk IPTC bytes are correct (checked by parsing the raw IPTC IIM dataset
/// directly — the `2:120` entry is present with the right value; `exiftool`'s own read agrees).
/// Both `CGImageSourceCopyPropertiesAtIndex`'s IPTC dictionary and
/// `CGImageMetadataCreateFromXMPData`'s `dc:description` come back empty; byline/copyright/keywords
/// in the same file read correctly. `SourceBrowserViewModel.loadArtFilterTokenIfNeeded()` papers
/// over this the same way it already does for maker-note fields: one lazy `exiftool` read per
/// selected asset corrects `descriptionText` if this reader got it wrong.
///
/// macOS 27 (Golden Gate, 2026) note: Core Image RAW 9 overhauled `CIRAWFilter`'s demosaic/denoise
/// quality, but `extractPreview` below doesn't go through `CIRAWFilter` — it pulls the camera's own
/// embedded JPEG preview via `CGImageSourceCreateThumbnailAtIndex`, so RAW 9 has no effect on this
/// reader's output. It would only become relevant if this app added a full-quality RAW render path.
/// Also confirmed: ImageIO/`CGImageDestination` gained no new EXIF/IPTC/XMP write coverage in
/// macOS 27, so `exiftool` remains the only reliable write path — no change to the scope gap above.
struct NativeMetadataReader {
    /// Reads the raw ImageIO property dictionary (EXIF/IPTC/GPS/TIFF sub-dictionaries) for one
    /// file. Works on JPEG and on RAW formats macOS has a built-in decoder for, including ORF.
    func readMetadata(at url: URL) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else {
            throw NativeMetadataError.unreadableFile
        }
        return properties
    }

    /// Maps the raw ImageIO dictionary onto the fields `PhotoAsset` exposes today.
    func mapToPhotoAsset(url: URL, metadata: [String: Any]) -> PhotoAsset {
        var asset = PhotoAsset(id: url)

        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let iptc = metadata[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]

        let objectName = (iptc[kCGImagePropertyIPTCObjectName as String] as? String) ?? ""
        // Per docs/SPEC.md §4: no EXIF title yet, so the filename stem is the starting point
        // rather than a blank field — still user-editable, just not empty on first load.
        asset.title = objectName.isEmpty ? url.deletingPathExtension().lastPathComponent : objectName
        asset.descriptionText =
            (iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String)
            ?? (tiff[kCGImagePropertyTIFFImageDescription as String] as? String) ?? ""
        asset.keywords = (iptc[kCGImagePropertyIPTCKeywords as String] as? [String]) ?? []

        asset.cameraModel = (tiff[kCGImagePropertyTIFFModel as String] as? String) ?? ""
        asset.lensModel = (exif[kCGImagePropertyExifLensModel as String] as? String) ?? ""

        if let fNumber = Self.doubleValue(exif[kCGImagePropertyExifFNumber as String]) {
            asset.aperture = "f/\(Self.trimmedNumber(fNumber))"
        }
        if let exposureTime = Self.doubleValue(exif[kCGImagePropertyExifExposureTime as String]) {
            asset.shutterSpeed = Self.shutterSpeedText(exposureTime)
        }
        if let focalLength = Self.doubleValue(exif[kCGImagePropertyExifFocalLength as String]) {
            asset.focalLength = "\(Self.trimmedNumber(focalLength)) mm"
        }
        if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
            let iso = isoValues.first
        {
            asset.iso = String(iso)
        }
        if let dateText = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            asset.capturedAt = Self.parseExifDate(dateText)
        }

        if let latitude = Self.doubleValue(gps[kCGImagePropertyGPSLatitude as String]),
            let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String
        {
            asset.gpsLatitude = latitudeRef.uppercased() == "S" ? -latitude : latitude
        }
        if let longitude = Self.doubleValue(gps[kCGImagePropertyGPSLongitude as String]),
            let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String
        {
            asset.gpsLongitude = longitudeRef.uppercased() == "W" ? -longitude : longitude
        }
        if let altitude = Self.doubleValue(gps[kCGImagePropertyGPSAltitude as String]) {
            let belowSeaLevel = (gps[kCGImagePropertyGPSAltitudeRef as String] as? Int) == 1
            asset.gpsAltitude = belowSeaLevel ? -altitude : altitude
        }

        return asset
    }

    /// Extracts a preview image without decoding full RAW pixel data — the native equivalent of
    /// exiftool's `-b -PreviewImage`. `kCGImageSourceCreateThumbnailWithTransform` applies the
    /// EXIF orientation for us, so (unlike the exiftool path in `image_loader.py`/
    /// `ExifToolClient`) there's no separate manual orientation-correction step needed.
    func extractPreview(at url: URL, maxPixelSize: Int = 2048) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NativeMetadataError.unreadableFile
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw NativeMetadataError.unreadableFile
        }
        return thumbnail
    }

    /// Same as `extractPreview(at:maxPixelSize:)` but decodes on a background thread — for
    /// SwiftUI callers, where decoding a RAW preview on the caller's actor would block the UI.
    /// `Task.detached` is what actually opts out of inheriting the calling `@MainActor` context;
    /// see docs/ARCHITECTURE.md's concurrency rules.
    func extractPreviewAsync(at url: URL, maxPixelSize: Int = 2048) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            try self.extractPreview(at: url, maxPixelSize: maxPixelSize)
        }.value
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Rounds to 2 decimal places before formatting — ImageIO hands back some RAW rational values
    /// (e.g. Olympus f-numbers) with Float32-to-Double conversion noise, such as 6.300000190736682
    /// instead of 6.3, so a plain `String(value)` would surface that noise directly in the UI.
    private static func trimmedNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rounded)) : String(rounded)
    }

    private static func shutterSpeedText(_ exposureTime: Double) -> String {
        guard exposureTime > 0 else { return "" }
        if exposureTime >= 1 {
            return "\(trimmedNumber(exposureTime))s"
        }
        return "1/\(Int((1 / exposureTime).rounded()))"
    }

    private static func parseExifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: text)
    }
}
