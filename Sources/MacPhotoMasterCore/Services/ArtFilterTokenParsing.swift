import Foundation

/// Derives `RenameContext.artFilterToken` from `exiftool`'s raw JSON metadata dict. Ported from
/// the Python reference app's `ExifService._art_filter_token` — only this one field, not the rest
/// of `exif_service.py`'s field mapping, since `NativeMetadataReader` already covers title/camera/
/// lens/GPS/etc. more cheaply via ImageIO (see its doc comment for the maker-note gap this fills).
/// Kept separate from `ExifToolClient` so it's unit testable without shelling out, mirroring
/// `MetadataEditParsing`'s split.
public enum ArtFilterTokenParsing {
    /// Checked in this priority order, matching the reference app exactly: an active Art Filter
    /// effect wins; falling back to a Picture Mode color profile, then a stacked-image state, then
    /// Live Composite/multiple-exposure. Olympus surfaces these as separate maker-note tags
    /// depending on shooting mode, so a single tag lookup isn't enough.
    public static func token(from metadata: [String: Any]) -> String {
        let artEffect = firstText(
            metadata,
            keys: ["Olympus:ArtFilterEffect", "EXIF:ArtFilterEffect", "MakerNotes:ArtFilterEffect"])
        let first = firstSemicolonText(artEffect)
        if !first.isEmpty, first.caseInsensitiveCompare("off") != .orderedSame {
            return first
        }

        let pictureMode = firstText(metadata, keys: ["Olympus:PictureMode", "EXIF:PictureMode"])
        let pictureFirst = firstSemicolonText(pictureMode)
        if pictureFirst.lowercased().contains("profile") {
            return pictureFirst
        }

        let stacked = firstText(
            metadata,
            keys: ["Olympus:StackedImage", "Olympus:StackedImages", "EXIF:StackedImage"])
        let stackedFirst = firstSemicolonText(stacked)
        if !stackedFirst.isEmpty, stackedFirst.caseInsensitiveCompare("no") != .orderedSame {
            return stackedFirst
        }

        let multipleExposure = firstText(
            metadata, keys: ["Olympus:MultipleExposureMode", "EXIF:MultipleExposureMode"])
        if multipleExposure.lowercased().hasPrefix("on") {
            return "MultipleExposure"
        }

        return ""
    }

    private static func firstText(_ metadata: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = metadata[key] else { continue }
            let text = toText(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// exiftool's JSON output puts list-valued tags (rare for these fields, but possible) as JSON
    /// arrays rather than pre-joined strings — mirrors the reference app's `_to_text`.
    private static func toText(_ value: Any) -> String {
        if let array = value as? [Any] {
            return array.map { toText($0) }.joined(separator: ", ")
        }
        return String(describing: value)
    }

    /// Returns the text before the first `;` (trimmed) — exiftool's PrintConv text for these tags
    /// is often `"Dramatic Tone; Yes; 0"` (effect name; on/off; extra param), and only the first
    /// segment is the human-readable token.
    private static func firstSemicolonText(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        return value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }
}
