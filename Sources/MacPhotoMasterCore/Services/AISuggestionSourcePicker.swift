import Foundation

/// Picks which capture-set member's image to send to an AI provider — docs/SPEC.md §6: "prefer
/// sending a RAW/unfiltered image to the AI over a heavily in-camera-filtered JPEG representative
/// when both exist in a set... an Art-Filter-Bracket JPEG skews AI description/keyword output
/// toward the filter effect rather than the actual scene." This deliberately overrides
/// `CaptureSet.representative`'s own JPEG-first pick (which favors JPEGs for a fast thumbnail/
/// display representative — a different concern), mirroring the Python reference app's
/// `pick_ai_source_path`.
public enum AISuggestionSourcePicker {
    private static let jpegExtensions: Set<String> = ["jpg", "jpeg"]

    /// First non-JPEG (RAW) member by filename, falling back to `CaptureSet.representative` (first
    /// JPEG by filename, or the first member) when the set has no RAW file at all.
    public static func pickSourceAsset(from members: [PhotoAsset]) -> PhotoAsset? {
        let sortedMembers = members.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        if let raw = sortedMembers.first(where: { !jpegExtensions.contains($0.url.pathExtension.lowercased()) }) {
            return raw
        }
        return sortedMembers.first
    }
}
