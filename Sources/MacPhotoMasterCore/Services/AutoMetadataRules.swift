import Foundation

/// Metadata rules applied only at write time (save/process), never shown live in the editable
/// fields — docs/SPEC.md §6: "a 'straight out of camera' keyword on unedited JPEGs, and an appended
/// note when an in-camera filter/effect was active." Ported from the Python reference app's
/// `services/auto_metadata.py`; pure functions so `SourceBrowserViewModel.saveMetadata` and
/// `ProcessMoveService.processAndCopy` can both apply them without any shared I/O state, mirroring
/// `MetadataEditParsing`'s split.
public enum AutoMetadataRules {
    private static let soocJPEGExtensions: Set<String> = ["jpg", "jpeg"]

    /// `"sooc"` for an unedited JPEG (this app never edits pixels, so any JPEG on disk is
    /// straight-out-of-camera by definition), else empty.
    public static func soocToken(for url: URL) -> String {
        soocJPEGExtensions.contains(url.pathExtension.lowercased()) ? "sooc" : ""
    }

    /// The rule above, minus its one exception: a `RawDevelopService` output is a JPEG by extension
    /// but emphatically not straight out of camera — Apple's RAW engine rendered it, which is the
    /// whole reason it exists.
    public static func soocToken(for asset: PhotoAsset) -> String {
        asset.derivedFrom == nil ? soocToken(for: asset.url) : ""
    }

    /// The in-camera look string for Instructions, or empty when the file never received that
    /// rendering.
    ///
    /// A RAW carries the look's *readings* but not the look. Measured on a real pair
    /// (H1071885.JPG/.ORF, 2026-08-09): the files differ in exactly one tag — `PictureMode` reverts
    /// to `"Natural"` in the ORF — while `ColorCreatorEffect` is byte-for-byte identical in both. So
    /// the parser legitimately returns a full look for an ORF, and writing it would annotate the
    /// file with a rendering Apple's engine never applied, since it does not read Olympus maker
    /// notes. A `RawDevelopService` output is the same story one step on, which is why it shares
    /// `soocToken(for:)`'s `derivedFrom` test: a JPEG by extension, but Apple's rendering of the
    /// RAW rather than the camera's.
    public static func cameraLookInstructions(for asset: PhotoAsset) -> String {
        guard !PhotoAssetLoader.isRaw(asset.url), asset.derivedFrom == nil else { return "" }
        return asset.cameraLookSummary
    }

    /// Appends camera/lens/art-filter/SOOC tokens to `keywords`, case-insensitively de-duplicated
    /// against what's already there and against each other. Blank tokens are skipped.
    public static func keywordsWithAutoTokens(
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
    public static func descriptionWithArtFilterNote(_ description: String, artFilterToken: String?) -> String {
        let trimmedToken = (artFilterToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return description }
        let note = "In camera effect \(trimmedToken)."
        guard !description.contains(note) else { return description }
        return description.isEmpty ? note : "\(description) \(note)"
    }
}
