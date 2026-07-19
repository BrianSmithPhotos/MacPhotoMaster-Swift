import Foundation

/// Scans a folder for supported image files and reads their metadata. See docs/SPEC.md §1 for
/// supported file types.
///
/// Uses `NativeMetadataReader` rather than `ExifToolClient` for this pass: ImageIO has no
/// external-process cost, so there's no batching concern the way there is for exiftool (see
/// docs/ARCHITECTURE.md "exiftool integration"), which makes it the better fit for scanning an
/// entire folder just to populate the browsing grid. The known gap — no manufacturer maker-note
/// fields, e.g. Olympus `ArtFilterEffect` — doesn't block browsing; `ExifToolClient` remains the
/// source of truth once full-fidelity fields are needed (metadata write-back, rename).
public struct PhotoAssetLoader {
    public init() {}

    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "orf"]

    /// Caps how many files are read at once. Each `NativeMetadataReader` read is CPU-bound
    /// (ImageIO parsing, no network/disk wait once the file's paged in), so throughput is bounded
    /// by core count — spawning one child task per file in a full SD card's worth of photos would
    /// just add scheduling overhead past that point without reading anything faster.
    private static let maxConcurrentReads = ProcessInfo.processInfo.activeProcessorCount

    /// Scans the folder and reads metadata for every supported file. A file that fails to read
    /// (corrupt, unsupported RAW variant) is skipped rather than failing the whole folder.
    ///
    /// Runs on `Task.detached` rather than as a plain `async` function: directory enumeration plus
    /// N ImageIO reads is real blocking work, and an unstructured task created from a `@MainActor`
    /// caller (this is called from `SourceBrowserViewModel`) otherwise inherits that caller's
    /// actor — `detached` is what actually opts out and moves the work to a background thread, per
    /// docs/ARCHITECTURE.md's concurrency rules.
    public func loadAssets(in folderURL: URL) async throws -> [PhotoAsset] {
        try await Task.detached(priority: .userInitiated) {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let imageURLs = contents.filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }

            return await Self.readAssets(at: imageURLs)
        }.value
    }

    /// Fans reads out across up to `maxConcurrentReads` child tasks at a time: start that many,
    /// then every time one finishes, pull the next URL off the front of the queue and start
    /// another, until the queue's empty. `TaskGroup` child tasks (unlike a plain `for` loop) run
    /// concurrently with each other, which is what actually lets multiple cores work through the
    /// folder in parallel instead of one file at a time.
    private static func readAssets(at urls: [URL]) async -> [PhotoAsset] {
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(urls.count)
        var nextIndex = 0

        await withTaskGroup(of: PhotoAsset?.self) { group in
            func startNextReadIfAny() {
                guard nextIndex < urls.count else { return }
                let url = urls[nextIndex]
                nextIndex += 1
                group.addTask {
                    let reader = NativeMetadataReader()
                    guard let metadata = try? reader.readMetadata(at: url) else { return nil }
                    return reader.mapToPhotoAsset(url: url, metadata: metadata)
                }
            }

            for _ in 0..<min(maxConcurrentReads, urls.count) {
                startNextReadIfAny()
            }
            while let asset = await group.next() {
                if let asset {
                    assets.append(asset)
                }
                startNextReadIfAny()
            }
        }

        return assets
    }
}
