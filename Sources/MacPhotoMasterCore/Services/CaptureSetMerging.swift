import Foundation

/// Applies the user's manual capture-set merges on top of what `CaptureGroupingService` worked out
/// from the camera's own signals. See docs/SPEC.md §1.
///
/// The camera can only tell us what it recorded, and there are captures it has no counter for — a
/// hand-shot sequence of 150 frames the photographer thinks of as one thing, or an interval run on a
/// body that stamps no interval index. This is the manual override for those: pick the sets in the
/// browser, merge, and the choice is remembered per folder by `CaptureSetMergeStore`.
///
/// Merging is keyed by member file path rather than by set id, because set ids are regenerated on
/// every load. A merge therefore survives a reload, and also survives regrouping — if a merged set
/// later gains a member (a developed RAW joining its original's frame), that member arrives inside
/// an already-merged group and comes along with it.
public enum CaptureSetMerging {
    /// Combines groups that share a merge id, leaving every other group untouched.
    ///
    /// A merged set takes the position and the id of its earliest constituent, so the browser's
    /// chronological order holds and the surviving tile keeps the thumbnail it already decoded.
    public static func apply(
        _ groups: [CaptureSet], mergeIDsByAssetPath: [String: String]
    ) -> [CaptureSet] {
        guard !mergeIDsByAssetPath.isEmpty else { return groups }

        var merged: [CaptureSet] = []
        var indexByMergeID: [String: Int] = [:]

        for group in groups {
            guard let mergeID = mergeID(of: group, mergeIDsByAssetPath: mergeIDsByAssetPath) else {
                merged.append(group)
                continue
            }
            if let existing = indexByMergeID[mergeID] {
                merged[existing].members += group.members
            } else {
                indexByMergeID[mergeID] = merged.count
                merged.append(group)
            }
        }

        return merged
    }

    /// The merge a group belongs to, or `nil` if none of its members were merged. The first member
    /// with a recorded id decides: a group only ever gets its members from one merge, since merging
    /// records every member of every set involved.
    private static func mergeID(
        of group: CaptureSet, mergeIDsByAssetPath: [String: String]
    ) -> String? {
        for member in group.members {
            if let mergeID = mergeIDsByAssetPath[member.url.path] { return mergeID }
        }
        return nil
    }
}
