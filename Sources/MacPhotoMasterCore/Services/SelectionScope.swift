import Foundation

/// Pure helpers for resolving multi-select action scope. Kept separate from
/// `SourceBrowserViewModel` so this logic is unit testable without a live view model — mirrors the
/// reference Python app's `selection_scope.py`. See docs/SPEC.md §1 "Manual multi-select" and §5's
/// `.manualSelection` scope.
public enum SelectionScope {
    /// Expands each id to its full capture-group membership, deduped, first-seen order preserved.
    /// A manual multi-selection in stacked view only selects representative tiles; without this
    /// expansion, an action would silently skip the other members of each selected set (e.g. the
    /// RAW file behind a stacked JPEG representative).
    public static func expandToCaptureGroups(
        _ ids: [PhotoAsset.ID], membersByID: [PhotoAsset.ID: [PhotoAsset.ID]]
    ) -> [PhotoAsset.ID] {
        var seen = Set<PhotoAsset.ID>()
        var expanded: [PhotoAsset.ID] = []
        for id in ids {
            for member in membersByID[id] ?? [id] where seen.insert(member).inserted {
                expanded.append(member)
            }
        }
        return expanded
    }

    /// The scope for an action on "the current selection" (the filmstrip's member list, and
    /// save/AI actions once those exist): when a multi-selection (more than one id) is active and
    /// includes `selected`, every selected id's full capture-group membership is unioned in.
    /// Otherwise just `selected`'s own capture-group membership (or itself alone, if it has none).
    public static func resolveScope(
        selected: PhotoAsset.ID,
        multiSelected: [PhotoAsset.ID],
        membersByID: [PhotoAsset.ID: [PhotoAsset.ID]]
    ) -> [PhotoAsset.ID] {
        if multiSelected.count > 1, multiSelected.contains(selected) {
            return expandToCaptureGroups(multiSelected, membersByID: membersByID)
        }
        return membersByID[selected] ?? [selected]
    }

    /// The contiguous run of `visible` between `anchor` and `target`, inclusive, for shift-click
    /// range selection — order-independent (ranging backward gives the same set as forward). Falls
    /// back to just `target` when either endpoint isn't currently visible (e.g. a stale anchor
    /// after a folder/grouping change).
    public static func rangeBetween(
        anchor: PhotoAsset.ID, target: PhotoAsset.ID, visible: [PhotoAsset.ID]
    ) -> Set<PhotoAsset.ID> {
        guard let start = visible.firstIndex(of: anchor), let end = visible.firstIndex(of: target) else {
            return [target]
        }
        return Set(visible[min(start, end)...max(start, end)])
    }
}
