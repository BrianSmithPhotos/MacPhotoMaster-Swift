import Foundation

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
/// (`exiftool` isn't available in the iOS/iPadOS sandbox — see docs/ARCHITECTURE.md), so the
/// sidecar's raw XMP bytes are parsed directly by `SidecarDraftParsing`, which this shares with the
/// Mac app's iPad import — see that type for the ImageIO quirks the parse works around.
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
        try SidecarDraftParsing.draft(at: try stagedSidecarURL(for: assetURL))
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

}
