import Foundation

/// One file on disk plus the EXIF fields the app cares about. See docs/SPEC.md §2.
struct PhotoAsset: Identifiable, Hashable {
    let id: URL
    var url: URL { id }

    var title: String = ""
    var descriptionText: String = ""
    var keywords: [String] = []

    var cameraModel: String = ""
    var lensModel: String = ""
    var aperture: String = ""
    var shutterSpeed: String = ""
    var focalLength: String = ""
    var iso: String = ""
    /// Olympus/OM System maker-note field (e.g. "16.03 m") — like `artFilterToken`, standard EXIF
    /// doesn't carry this reliably, so `NativeMetadataReader`'s ImageIO scan can't read it; it's
    /// filled in the same lazy per-selection `exiftool` pass as `artFilterToken`.
    var focusDistance: String = ""

    var capturedAt: Date?
    var artFilterToken: String?

    var gpsLatitude: Double?
    var gpsLongitude: Double?
    var gpsAltitude: Double?
}
