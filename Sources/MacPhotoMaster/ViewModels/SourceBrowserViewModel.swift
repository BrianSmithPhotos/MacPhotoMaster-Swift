import Foundation

/// Holds the currently-browsed folder's capture sets and the current selection. Views bind to
/// this via `@StateObject`/`@ObservedObject`; it owns no I/O itself — it kicks off `Service` calls
/// from a `Task` and republishes the results, per docs/ARCHITECTURE.md "Layers".
///
/// `@MainActor` on the class means every property and method here is main-actor-isolated by
/// default: SwiftUI reads `@Published` properties on the main thread, so this guarantees those
/// reads never race the writes below. It's also why `loadFolder` doesn't need to hop back to the
/// main actor explicitly after `await` — the compiler already knows this whole class runs there,
/// and only the `await loader.loadAssets(...)` line itself briefly suspends onto the service's
/// background task.
@MainActor
final class SourceBrowserViewModel: ObservableObject {
    @Published private(set) var captureSets: [CaptureSet] = []
    @Published private(set) var subfolders: [URL] = []
    /// The path from the folder the user opened down to the folder currently displayed — e.g.
    /// `[card, DCIM, 100OLYMP]`. Drives the breadcrumb bar; see docs/SPEC.md §1 "folder tree" and
    /// `FolderBrowser`'s doc comment for why this is breadcrumb navigation rather than a recursive
    /// tree.
    @Published private(set) var breadcrumb: [URL] = []
    @Published private(set) var isLoading = false
    @Published var loadErrorMessage: String?
    @Published var selectedAssetID: PhotoAsset.ID?

    private let loader = PhotoAssetLoader()
    private let folderBrowser = FolderBrowser()
    private let grouping = CaptureGroupingService()

    /// Lazily created on first use rather than in `init` because `SkipStateStore.init` is
    /// throwing (it touches the filesystem to open/migrate the database) and `SourceBrowserViewModel`
    /// is constructed synchronously by SwiftUI (`@StateObject`). Cached after the first successful
    /// creation so every folder load doesn't reopen the database.
    private var skipStore: SkipStateStore?

    /// The folder a just-loaded `CaptureSet` belongs to, keyed by set id — needed by `skip(_:)`
    /// since by the time the user acts, `breadcrumb.last` may already point at a different folder
    /// (they could have navigated on).
    private var folderPathByCaptureSetID: [CaptureSet.ID: String] = [:]

    /// Called from the "Open Folder…" picker — starts a fresh breadcrumb rooted at the chosen
    /// folder. Anything previously open is discarded.
    func openFolder(at folderURL: URL) {
        breadcrumb = [folderURL]
        load(folderURL)
    }

    /// Called when the user clicks a subfolder tile or a breadcrumb segment. Clicking an ancestor
    /// already in the breadcrumb truncates back to it (like clicking a Finder path-bar segment);
    /// clicking a subfolder appends one level.
    func navigate(to folderURL: URL) {
        if let index = breadcrumb.firstIndex(of: folderURL) {
            breadcrumb.removeSubrange((index + 1)...)
        } else {
            breadcrumb.append(folderURL)
        }
        load(folderURL)
    }

    /// Fire-and-forget from the View's perspective: starts an unstructured `Task` so the caller
    /// (a SwiftUI button/tap action) doesn't need to be `async` itself. Re-entrant calls just
    /// replace whatever the previous load was populating.
    ///
    /// The two `async let`s run concurrently — unlike `Task { }`, `async let` creates a
    /// *structured* child task: it's automatically awaited (and cancelled, if this enclosing
    /// `Task` is cancelled) by the time this scope exits, so there's no separate lifetime to
    /// manage the way there would be with two unstructured `Task { }`s.
    private func load(_ folderURL: URL) {
        isLoading = true
        loadErrorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                async let assetsTask = loader.loadAssets(in: folderURL)
                async let subfoldersTask = folderBrowser.subfolders(of: folderURL)
                let (assets, folders) = try await (assetsTask, subfoldersTask)
                let skippedPaths = await skippedAssetPaths(inFolder: folderURL)
                let allSets = grouping.group(assets)
                captureSets = allSets.filter { set in
                    guard let representativePath = set.representative?.url.path else { return true }
                    return !skippedPaths.contains(representativePath)
                }
                folderPathByCaptureSetID = Dictionary(
                    uniqueKeysWithValues: captureSets.map { ($0.id, folderURL.path) })
                subfolders = folders
                selectedAssetID = captureSets.first?.representative?.id
            } catch {
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    /// Hides every member of `captureSet` from the current view and persists that choice so it
    /// stays hidden if this folder is reopened later. Never touches the files on disk — see
    /// `SkipStateStore`'s doc comment for why "skip" is view-only.
    func skip(_ captureSet: CaptureSet) {
        guard let folderPath = folderPathByCaptureSetID[captureSet.id] else { return }
        Task {
            guard let store = await ensureSkipStore() else { return }
            let assetPaths = captureSet.members.map(\.url.path)
            try? await store.skip(assetPaths: assetPaths, inFolder: folderPath)

            captureSets.removeAll { $0.id == captureSet.id }
            folderPathByCaptureSetID.removeValue(forKey: captureSet.id)
            if selectedAssetID == captureSet.representative?.id {
                selectedAssetID = captureSets.first?.representative?.id
            }
        }
    }

    private func skippedAssetPaths(inFolder folderURL: URL) async -> Set<String> {
        guard let store = await ensureSkipStore() else { return [] }
        return (try? await store.skippedAssetPaths(inFolder: folderURL.path)) ?? []
    }

    private func ensureSkipStore() async -> SkipStateStore? {
        if let skipStore { return skipStore }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "skip_state.sqlite3")
            let store = try SkipStateStore(databasePath: databasePath)
            skipStore = store
            return store
        } catch {
            loadErrorMessage = error.localizedDescription
            return nil
        }
    }

    var selectedAsset: PhotoAsset? {
        captureSets
            .flatMap(\.members)
            .first { $0.id == selectedAssetID }
    }

    /// The capture set the selected tile belongs to — `selectedAssetID` always holds a
    /// representative's id (see `load` and the grid's tap gesture), so matching on `representative`
    /// finds it directly rather than needing to search every member.
    var selectedCaptureSet: CaptureSet? {
        captureSets.first { $0.representative?.id == selectedAssetID }
    }

    /// Keyboard-shortcut entry point for skipping the current selection — see `SourcePanelView`'s
    /// delete-key binding. No-op with nothing selected.
    func skipSelected() {
        guard let selectedCaptureSet else { return }
        skip(selectedCaptureSet)
    }
}
