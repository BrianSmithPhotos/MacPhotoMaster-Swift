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
    @Published private(set) var isLoading = false
    @Published var loadErrorMessage: String?
    @Published var selectedAssetID: PhotoAsset.ID?

    private let loader = PhotoAssetLoader()
    private let grouping = CaptureGroupingService()

    /// Fire-and-forget from the View's perspective: starts an unstructured `Task` so the caller
    /// (a SwiftUI button action) doesn't need to be `async` itself. Re-entrant calls just replace
    /// whatever the previous load was populating.
    func loadFolder(at folderURL: URL) {
        isLoading = true
        loadErrorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let assets = try await loader.loadAssets(in: folderURL)
                let sets = grouping.group(assets)
                captureSets = sets
                selectedAssetID = sets.first?.representative?.id
            } catch {
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    var selectedAsset: PhotoAsset? {
        captureSets
            .flatMap(\.members)
            .first { $0.id == selectedAssetID }
    }
}
