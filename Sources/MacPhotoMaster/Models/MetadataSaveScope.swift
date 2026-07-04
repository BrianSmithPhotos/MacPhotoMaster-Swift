import Foundation

/// Which photos a metadata save action should act on — see docs/SPEC.md §3's two save scopes, plus
/// `.manualSelection` for AI-suggestion auto-save (docs/SPEC.md §6), which can span more than one
/// capture set. Still narrower than `ProcessMoveScope`: no whole-session scope, since there's no UI
/// action that saves metadata across an entire folder at once.
enum MetadataSaveScope {
    case singleAsset(PhotoAsset)
    case captureSet(CaptureSet)
    /// A multi-capture-set (or narrowed filmstrip) selection — see
    /// `SourceBrowserViewModel.manualSelectionAssets`. Only ever constructed by `suggestAI()`'s
    /// auto-save; the manual Save buttons in `MetadataPanelView` still only offer This File/Capture
    /// Set.
    case manualSelection([PhotoAsset])
}
