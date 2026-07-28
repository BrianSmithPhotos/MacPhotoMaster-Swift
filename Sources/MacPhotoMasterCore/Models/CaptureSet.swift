import Foundation

/// A group of assets captured within the same second. See docs/SPEC.md §1 for the grouping and
/// representative-selection rules.
public struct CaptureSet: Identifiable {
    public let id: UUID = UUID()
    public var members: [PhotoAsset]

    /// First JPG/JPEG in filename order, else the first member in filename order. See docs/SPEC.md §1.
    ///
    /// RAW-developed members are considered only when a set holds nothing else — the rule above is
    /// applied to the camera's own files first. Developing a file must not change which asset
    /// represents its set: skip and processed state are keyed by the representative's path, so a
    /// derived JPEG outranking the ORF it came from would silently detach the set from state
    /// already recorded against it.
    public var representative: PhotoAsset? {
        Self.preferred(among: members.filter { $0.derivedFrom == nil }) ?? Self.preferred(among: members)
    }

    private static func preferred(among members: [PhotoAsset]) -> PhotoAsset? {
        let sortedMembers = members.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        return sortedMembers.first { $0.url.pathExtension.lowercased() == "jpg" || $0.url.pathExtension.lowercased() == "jpeg" }
            ?? sortedMembers.first
    }
}
