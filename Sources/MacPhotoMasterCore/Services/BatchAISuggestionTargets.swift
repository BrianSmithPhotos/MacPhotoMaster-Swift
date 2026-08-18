import Foundation

/// Which capture sets a batch AI run covers. Kept apart from the view model because it is the one
/// part of the run that can be wrong silently: describing a set the user meant to keep, or skipping
/// one they meant to describe, is invisible until the files are already written.
public enum BatchAISuggestionTargets {
    /// The sets to suggest for, in grid order.
    ///
    /// A multi-selection wins when there is one — that is the user pointing at exactly what they
    /// want — and otherwise the whole folder is the target, since running over everything is the
    /// point of a batch. *Two or more* sets, though: clicking a single tile already fills the
    /// selection with that one id, so honouring a selection of one would quietly shrink every batch
    /// run to whichever set the cursor happened to be on. The app draws the same line elsewhere
    /// (`SourceBrowserViewModel.hasMultiSelection`). Sets that already carry a description are left
    /// alone unless `redescribingDescribed` says otherwise: a batch run is unattended, and
    /// overwriting prose the user wrote by hand would be the one loss they could not undo from here.
    ///
    /// Skipped sets never appear, for free rather than by rule: `captureSets` already excludes them.
    public static func sets(
        in captureSets: [CaptureSet], multiSelectedRepresentativeIDs: Set<PhotoAsset.ID>,
        redescribingDescribed: Bool
    ) -> [CaptureSet] {
        let selected = captureSets.filter { set in
            guard let representativeID = set.representative?.id else { return false }
            return multiSelectedRepresentativeIDs.contains(representativeID)
        }
        let candidates = selected.count > 1 ? selected : captureSets
        guard !redescribingDescribed else { return candidates }
        return candidates.filter { !hasDescription($0) }
    }

    /// Whether a set counts as already described. Any member with description text does it, not just
    /// the representative: a save writes the whole set, so a set with prose on only some of its
    /// members is a set someone has already worked on.
    private static func hasDescription(_ captureSet: CaptureSet) -> Bool {
        captureSet.members.contains {
            !$0.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
