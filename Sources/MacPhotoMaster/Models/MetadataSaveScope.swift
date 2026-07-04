import Foundation

/// Which photos a metadata save action should act on — see docs/SPEC.md §3's two save scopes, plus
/// `.manualSelection` for AI-suggestion auto-save (docs/SPEC.md §6), which can span more than one
/// capture set. Still narrower than `ProcessMoveScope`: no whole-session scope, since there's no UI
/// action that saves metadata across an entire folder at once.
enum MetadataSaveScope {
    case singleAsset(PhotoAsset)
    case captureSet(CaptureSet)
    /// A multi-capture-set (or narrowed filmstrip) selection — see
    /// `SourceBrowserViewModel.manualSelectionAssets`. Constructed by `suggestAI()`'s auto-save and
    /// by the "Save (Current Selection)" button in `MetadataPanelView`.
    case manualSelection([PhotoAsset])
}
