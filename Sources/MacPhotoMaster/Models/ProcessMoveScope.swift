import Foundation

/// Which photos a process/move action should act on — see docs/SPEC.md §5's four scopes. Manual
/// selection isn't included yet: the app has no multi-select model, only a single
/// `SourceBrowserViewModel.selectedAssetID`, so there's nothing yet for that scope to resolve
/// against.
enum ProcessMoveScope {
    case singleAsset(PhotoAsset)
    case captureSet(CaptureSet)
    case session([CaptureSet])

    /// Flattens the scope to the concrete list of assets a process/move action should copy.
    var assets: [PhotoAsset] {
        switch self {
        case .singleAsset(let asset):
            return [asset]
        case .captureSet(let captureSet):
            return captureSet.members
        case .session(let captureSets):
            return captureSets.flatMap(\.members)
        }
    }
}
