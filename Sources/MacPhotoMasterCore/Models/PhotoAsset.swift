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
    /// The in-camera creative-dial settings as one readable string (see `CameraLookParsing`),
    /// written to IPTC/XMP Instructions on process/move. Read from the same lazy `exiftool` pass as
    /// `artFilterToken`, and empty for anything that wasn't shot with the dial engaged.
    public var cameraLook: String = ""

    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?

    /// The RAW file this asset was developed from, for a `RawDevelopService` output — `nil` for
    /// every file that came off the camera. One field doing three jobs: it marks the asset as
    /// derived, it names the original whose filename the rename must be built from (the derivative
    /// lives under a staging key, whose digits `RenameService.sequence(from:)` would otherwise
    /// harvest), and it keys `RawDerivedStore`.
    public var derivedFrom: URL?
}
