import Foundation

/// One file on disk plus the EXIF fields the app cares about. See docs/SPEC.md §2.
public struct PhotoAsset: Identifiable, Hashable {
    public let id: URL
    public var url: URL { id }

    public var title: String = ""
    public var descriptionText: String = ""
    public var keywords: [String] = []

    public var cameraModel: String = ""
    public var lensModel: String = ""
    public var aperture: String = ""
    public var shutterSpeed: String = ""
    public var focalLength: String = ""
    public var iso: String = ""
    /// Olympus/OM System maker-note field (e.g. "16.03 m") — like `artFilterToken`, standard EXIF
    /// doesn't carry this reliably, so `NativeMetadataReader`'s ImageIO scan can't read it; it's
    /// filled in the same lazy per-selection `exiftool` pass as `artFilterToken`.
    public var focusDistance: String = ""

    public var capturedAt: Date?
    public var artFilterToken: String?

    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?
}
