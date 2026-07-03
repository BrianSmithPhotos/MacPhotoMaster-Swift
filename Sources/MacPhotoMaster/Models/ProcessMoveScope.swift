import Foundation

/// Which photos a process/move action should act on — see docs/SPEC.md §5's four scopes.
enum ProcessMoveScope {
    case singleAsset(PhotoAsset)
    case captureSet(CaptureSet)
    /// The grid's manual multi-selection (docs/SPEC.md §1), expanded to full capture-group
    /// membership — see `SourceBrowserViewModel.manualSelectionAssets`/`SelectionScope`.
    case manualSelection([PhotoAsset])
    case session([CaptureSet])

    /// Flattens the scope to the concrete list of assets a process/move action should copy.
    var assets: [PhotoAsset] {
        switch self {
        case .singleAsset(let asset):
            return [asset]
        case .captureSet(let captureSet):
            return captureSet.members
        case .manualSelection(let assets):
            return assets
        case .session(let captureSets):
            return captureSets.flatMap(\.members)
        }
    }
}
