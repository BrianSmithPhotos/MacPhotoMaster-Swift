import Foundation

/// Common interface for anything that can save Title/Description/Keywords/GPS to a photo —
/// `ExifToolClient` writes directly into the file; `NativeMetadataWriter` writes an XMP sidecar
/// instead (see its doc comment for why a direct write isn't safe on every platform/format).
/// Callers that only need to save edited fields can depend on this instead of a concrete writer.
protocol MetadataWriter {
    /// `title` is per-file-unique (usually rename-derived), so it's only exposed here, never in
    /// the batched overload below — see docs/SPEC.md §3.
    func write(title: String?, description: String, keywords: [String], gps: GPSCoordinate?, to url: URL) async throws

    /// Writes the same description/keywords/GPS to every file in `urls`.
    func write(description: String, keywords: [String], gps: GPSCoordinate?, to urls: [URL]) async throws
        -> [URL: Result<Void, Error>]
}
