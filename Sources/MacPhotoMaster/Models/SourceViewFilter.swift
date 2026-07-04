import Foundation

/// Which capture sets the source grid displays — see `SourceBrowserViewModel.captureSets` /
/// `.skippedCaptureSets` and `SourcePanelView`'s segmented control. `.skipped` is a read-only,
/// un-skip-only view: skipped items aren't selectable for editing/process, only restorable to
/// `.active`.
enum SourceViewFilter {
    case active
    case skipped
}
