import Foundation

/// Lists the subfolders of a directory — directory-entry names only, no per-file metadata reads.
/// Backs the breadcrumb-style navigation in `SourceBrowserViewModel` (see docs/SPEC.md §1
/// "folder tree"; this app uses a one-level-at-a-time navigator rather than a recursive tree — see
/// docs/ARCHITECTURE.md's concurrency rules for why: a recursive `OutlineGroup` needs synchronous
/// filesystem access on every expand, which conflicts with routing filesystem access through an
/// async `Service` call).
struct FolderBrowser {
    /// Sorted with `localizedStandardCompare` (matches Finder's ordering, e.g. "100OLYMP" before
    /// "20OLYMP" the way a human reads it) rather than plain string comparison.
    ///
    /// Runs on `Task.detached` for the same reason as `PhotoAssetLoader.loadAssets` — called from
    /// a `@MainActor` view model, and `detached` is what actually opts out of inheriting that
    /// actor rather than just running on it.
    func subfolders(of folderURL: URL) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            return
                contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value
    }
}
