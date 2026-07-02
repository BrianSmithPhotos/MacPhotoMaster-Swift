import Foundation

/// A group of assets captured within the same second. See docs/SPEC.md §1 for the grouping and
/// representative-selection rules.
struct CaptureSet: Identifiable {
    let id: UUID = UUID()
    var members: [PhotoAsset]

    /// First JPG/JPEG in filename order, else the first member. See docs/SPEC.md §1.
    var representative: PhotoAsset? {
        members
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
            .first { $0.url.pathExtension.lowercased() == "jpg" || $0.url.pathExtension.lowercased() == "jpeg" }
            ?? members.first
    }
}
