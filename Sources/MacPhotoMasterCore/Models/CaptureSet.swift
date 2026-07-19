import Foundation

/// A group of assets captured within the same second. See docs/SPEC.md §1 for the grouping and
/// representative-selection rules.
public struct CaptureSet: Identifiable {
    public let id: UUID = UUID()
    public var members: [PhotoAsset]

    /// First JPG/JPEG in filename order, else the first member in filename order. See docs/SPEC.md §1.
    public var representative: PhotoAsset? {
        let sortedMembers = members.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        return sortedMembers.first { $0.url.pathExtension.lowercased() == "jpg" || $0.url.pathExtension.lowercased() == "jpeg" }
            ?? sortedMembers.first
    }
}
