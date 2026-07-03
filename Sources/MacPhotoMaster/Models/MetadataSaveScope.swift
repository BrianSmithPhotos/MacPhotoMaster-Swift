import Foundation

/// Which photos a metadata save action should act on — see docs/SPEC.md §3's two save scopes.
/// Deliberately narrower than `ProcessMoveScope`: metadata save only ever targets a single file or
/// a full capture set, never a manual selection or the whole session.
enum MetadataSaveScope {
    case singleAsset(PhotoAsset)
    case captureSet(CaptureSet)
}
