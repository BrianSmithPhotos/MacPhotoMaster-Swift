import Foundation

/// Which capture sets the source grid displays — see `SourceBrowserViewModel.captureSets` /
/// `.skippedCaptureSets` and `SourcePanelView`'s segmented control. Clicking a tile previews it the
/// same way in both filters; restoring a skipped item back to `.active` is a right-click
/// ("Un-skip") action only, never a side effect of previewing it.
public enum SourceViewFilter {
    case active
    case skipped
}
