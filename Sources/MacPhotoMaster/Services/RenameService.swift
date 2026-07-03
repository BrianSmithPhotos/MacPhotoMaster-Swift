import Foundation

/// The fields a rename decision needs, gathered from wherever they currently live (EXIF read,
/// the manual per-session batch label, an in-progress edit) — decoupled from `PhotoAsset` since
/// the caller may want to preview a rename against edited-but-not-yet-saved values.
struct RenameContext {
    var sourceURL: URL
    var capturedAt: Date?
    var cameraModel: String
    var lensModel: String
    /// Manual per-session label, not GPS-derived — see docs/SPEC.md §4.
    var batch: String
    var artFilterToken: String?
}

/// Computes the destination filename for a rename per docs/SPEC.md §4's
/// `sequence_batch_YYYYMMDD_HHMM_[artfilter]_camera_lens.ext` pattern. Pure computation only —
/// this never touches a file on disk. Renaming only ever applies to the *destination* copy made
/// during process/move (spec §5); the source file (e.g. on the SD card) is never renamed in place.
struct RenameService {
    private static let invalidFilenameCharacters: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
    private static let maxComponentLength = 64

    func buildFilename(for context: RenameContext) -> String {
        let sequence = Self.sequence(from: context.sourceURL)
        let (date, time) = Self.dateTimeParts(context.capturedAt)
        let batch = Self.sanitizeComponent(context.batch)
        let artFilter = Self.sanitizeComponent(context.artFilterToken ?? "")

        let sanitizedCamera = Self.sanitizeComponent(context.cameraModel)
        let camera = sanitizedCamera.isEmpty ? "UnknownCamera" : sanitizedCamera
        let sanitizedLens = Self.sanitizeComponent(context.lensModel)
        let lens = sanitizedLens.isEmpty ? "UnknownLens" : sanitizedLens

        var parts = [sequence]
        if !batch.isEmpty { parts.append(batch) }
        parts.append(date)
        parts.append(time)
        if !artFilter.isEmpty { parts.append(artFilter) }
        parts.append(camera)
        parts.append(lens)

        let sourceExtension = context.sourceURL.pathExtension
        let fileExtension = sourceExtension.isEmpty ? "jpg" : sourceExtension.lowercased()
        return "\(parts.joined(separator: "_")).\(fileExtension)"
    }

    /// Appends `_1`, `_2`, ... before the extension until `candidate` no longer collides with
    /// `existingNames` — never silently overwrites, per docs/SPEC.md §4. The caller decides what
    /// "existing" means (a destination directory listing, a batch's already-assigned names, or
    /// both) by however it builds `existingNames`.
    func ensureUniqueName(_ candidate: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(candidate) else { return candidate }
        let stem = (candidate as NSString).deletingPathExtension
        let fileExtension = (candidate as NSString).pathExtension
        var index = 1
        while true {
            let next = fileExtension.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(fileExtension)"
            if !existingNames.contains(next) { return next }
            index += 1
        }
    }

    /// Not a maintained counter — just the digits already burned into the source filename by the
    /// camera (e.g. `P1010042.JPG` -> `"1010042"`), passed through verbatim so the app's sequence
    /// tracks the camera's own numbering rather than inventing a separate one. `"0"` if the
    /// filename has no digits at all.
    private static func sequence(from sourceURL: URL) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let digits = stem.filter(\.isNumber)
        return digits.isEmpty ? "0" : digits
    }

    /// Uses `TimeZone.current` to match how `NativeMetadataReader.parseExifDate` parsed the
    /// original EXIF string — so the filename shows the same wall-clock digits the camera
    /// recorded, regardless of what timezone this Mac happens to be set to.
    private static func dateTimeParts(_ capturedAt: Date?) -> (date: String, time: String) {
        guard let capturedAt else { return ("UnknownDate", "UnknownTime") }
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        let date = formatter.string(from: capturedAt)
        formatter.dateFormat = "HHmm"
        let time = formatter.string(from: capturedAt)
        return (date, time)
    }

    /// Trims outer whitespace, replaces filesystem-invalid characters and whitespace runs with a
    /// single `-`, collapses repeated `-`, strips leading/trailing `-`/`.`, and caps length —
    /// applied identically to the batch, camera, lens, and art-filter segments.
    private static func sanitizeComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let replaced = String(trimmed.map { invalidFilenameCharacters.contains($0) ? "-" : $0 })
        let whitespaceCollapsed = replaced.replacingOccurrences(
            of: "\\s+", with: "-", options: .regularExpression)
        let dashCollapsed = whitespaceCollapsed.replacingOccurrences(
            of: "-{2,}", with: "-", options: .regularExpression)
        let trimmedDashesAndDots = dashCollapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return String(trimmedDashesAndDots.prefix(maxComponentLength))
    }
}
