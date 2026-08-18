import Foundation

/// Splits the folder's capture groups into the active and skipped lists both browsers display,
/// given the file paths `SkipStateStore` has recorded as skipped. See docs/SPEC.md §1.
///
/// Skip is per file, not per set. A group with only some members skipped therefore appears in
/// *both* lists — the frames still in play under "Active", the culled ones under "Skipped" — which
/// is what makes skipping one frame out of a focus bracket or a burst the same operation as
/// skipping the whole set: do it to every member and the active half simply empties. It also means
/// state written by the older set-at-a-time skip still reads back correctly, since that wrote a row
/// for every member.
///
/// Both halves keep the group's own id. They're rendered by separate `ForEach`es over separate
/// arrays (the source panel's segmented filter shows one at a time), so the shared id never has to
/// disambiguate them — and holding it steady is what stops SwiftUI from treating every tile as new,
/// and re-decoding a whole folder's thumbnails, each time one member is skipped.
public enum SkipPartition {
    public static func split(
        _ groups: [CaptureSet], skippedPaths: Set<String>
    ) -> (active: [CaptureSet], skipped: [CaptureSet]) {
        var active: [CaptureSet] = []
        var skipped: [CaptureSet] = []

        for group in groups {
            let skippedMembers = group.members.filter { skippedPaths.contains($0.url.path) }
            guard !skippedMembers.isEmpty else {
                active.append(group)
                continue
            }
            let activeMembers = group.members.filter { !skippedPaths.contains($0.url.path) }
            if !activeMembers.isEmpty {
                active.append(CaptureSet(members: activeMembers, id: group.id))
            }
            skipped.append(CaptureSet(members: skippedMembers, id: group.id))
        }

        return (active, skipped)
    }
}
