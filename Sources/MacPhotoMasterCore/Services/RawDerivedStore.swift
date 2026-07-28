import Foundation

/// Holds RAW-developed JPEGs in app-local storage until they are processed into the library, rather
/// than writing them beside their originals. The original is typically still on the camera card,
/// which may be full and is often still in use across a multi-day trip — the same reasoning
/// `SidecarStagingStore` documents for staged sidecars, and the reason both live under Application
/// Support.
///
/// Keyed by the original's name and size for that store's reason too: a card that isn't reformatted
/// between sessions can roll its DCIM numbering over, so a path isn't stable across sessions the way
/// it is for files on local disk.
public struct RawDerivedStore {
    private let stagingDirectory: URL

    /// `stagingDirectory` is created if it doesn't exist yet.
    public init(stagingDirectory: URL) throws {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        self.stagingDirectory = stagingDirectory
    }

    public static func makeDefault() throws -> RawDerivedStore {
        try RawDerivedStore(stagingDirectory: AppSupportDirectory.url(forFileNamed: "RawDerived"))
    }

    /// Where a develop run should write, and where the derivative is read back from afterwards.
    ///
    /// `<size>_<original name>.jpg`, keeping the original's extension in the middle: it costs
    /// nothing, makes a directory listing say plainly which file each derivative came from, and
    /// leaves the key unambiguous even for a `P1010042.ORF`/`P1010042.JPG` pair.
    public func derivedURL(for originalURL: URL) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: originalURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return stagingDirectory
            .appendingPathComponent("\(size)_\(originalURL.lastPathComponent)")
            .appendingPathExtension("jpg")
    }

    public func hasDerivative(for originalURL: URL) throws -> Bool {
        FileManager.default.fileExists(atPath: try derivedURL(for: originalURL).path)
    }

    /// Removes the derivative once it has been copied into the library (or when a develop is being
    /// redone). Goes to the Trash per CLAUDE.md "File Safety" — this is a real image file, and the
    /// cost of being wrong is a lost render rather than a recoverable one.
    ///
    /// A missing derivative is not an error: the caller discards after a successful process, and
    /// nothing guarantees the develop that produced it happened in this session.
    public func discard(for originalURL: URL) throws {
        let url = try derivedURL(for: originalURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Reads back every derivative staged for `originals`, ready to merge into the browsing grid.
    ///
    /// The metadata comes from the derived JPEG itself rather than being copied off the original:
    /// `RawDevelopService` renders through `CIContext.writeJPEGRepresentation`, which carries the
    /// RAW's EXIF through untouched, so the capture time that decides the derivative's capture set
    /// is the camera's own.
    public func derivedAssets(forOriginals originals: [PhotoAsset]) -> [PhotoAsset] {
        let reader = NativeMetadataReader()
        return originals.compactMap { original in
            guard let url = try? derivedURL(for: original.url),
                FileManager.default.fileExists(atPath: url.path),
                let metadata = try? reader.readMetadata(at: url)
            else {
                return nil
            }
            var asset = reader.mapToPhotoAsset(url: url, metadata: metadata)
            asset.derivedFrom = original.url
            return asset
        }
    }
}
