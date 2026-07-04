import Foundation

/// Metadata rules applied only at write time (save/process), never shown live in the editable
/// fields — docs/SPEC.md §6: "a 'straight out of camera' keyword on unedited JPEGs, and an appended
/// note when an in-camera filter/effect was active." Ported from the Python reference app's
/// `services/auto_metadata.py`; pure functions so `SourceBrowserViewModel.saveMetadata` and
/// `ProcessMoveService.processAndCopy` can both apply them without any shared I/O state, mirroring
/// `MetadataEditParsing`'s split.
enum AutoMetadataRules {
    private static let soocJPEGExtensions: Set<String> = ["jpg", "jpeg"]

    /// `"sooc"` for an unedited JPEG (this app never edits pixels, so any JPEG on disk is
    /// straight-out-of-camera by definition), else empty.
    static func soocToken(for url: URL) -> String {
        soocJPEGExtensions.contains(url.pathExtension.lowercased()) ? "sooc" : ""
    }

    /// Appends camera/lens/art-filter/SOOC tokens to `keywords`, case-insensitively de-duplicated
    /// against what's already there and against each other. Blank tokens are skipped.
    static func keywordsWithAutoTokens(
        _ keywords: [String], artFilterToken: String?, cameraToken: String?, lensToken: String?,
        soocToken: String
    ) -> [String] {
        var seenLowercased = Set(keywords.map { $0.lowercased() })
        var result = keywords
        for candidate in [artFilterToken ?? "", cameraToken ?? "", lensToken ?? "", soocToken] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seenLowercased.contains(trimmed.lowercased()) else { continue }
            seenLowercased.insert(trimmed.lowercased())
            result.append(trimmed)
        }
        return result
    }

    /// Appends `"In camera effect <token>."` to `description`, skipping if that exact note is
    /// already present (re-saving shouldn't duplicate it) or if there's no active filter token.
    static func descriptionWithArtFilterNote(_ description: String, artFilterToken: String?) -> String {
        let trimmedToken = (artFilterToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return description }
        let note = "In camera effect \(trimmedToken)."
        guard !description.contains(note) else { return description }
        return description.isEmpty ? note : "\(description) \(note)"
    }
}
