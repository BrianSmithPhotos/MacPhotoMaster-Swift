import Foundation

/// A GPS fix to write. Latitude/longitude are required together (an EXIF fix without one or the
/// other is meaningless), so pairing them in one type rules out that inconsistent state at compile
/// time rather than needing a runtime check like the Python reference app does. See docs/SPEC.md §3
/// for the Ref-tag-from-sign convention.
public struct GPSCoordinate: Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public enum MetadataWriteError: Error, Equatable {
    case invalidLatitude(Double)
    case invalidLongitude(Double)
}

/// Common interface for anything that can save Title/Description/Keywords/GPS to a photo —
/// `ExifToolClient` writes directly into the file; `NativeMetadataWriter` writes an XMP sidecar
/// instead (see its doc comment for why a direct write isn't safe on every platform/format).
/// Callers that only need to save edited fields can depend on this instead of a concrete writer.
public protocol MetadataWriter {
    /// `title` is per-file-unique (usually rename-derived), so it's only exposed here, never in
    /// the batched overload below — see docs/SPEC.md §3.
    func write(title: String?, description: String, keywords: [String], gps: GPSCoordinate?, to url: URL) async throws

    /// Writes the same description/keywords/GPS to every file in `urls`.
    func write(description: String, keywords: [String], gps: GPSCoordinate?, to urls: [URL]) async throws
        -> [URL: Result<Void, Error>]
}
