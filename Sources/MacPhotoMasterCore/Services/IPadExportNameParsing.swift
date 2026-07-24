import Foundation

/// Recovers the two `RenameContext` fields that can't be re-read from a file's metadata out of a
/// filename `RenameService` already produced.
///
/// Needed because iPad-processed files reach the Mac already renamed, but with the art-filter
/// segment missing — iOS has no exiftool, so `PhotoAsset.artFilterToken` is always empty there (see
/// `PhotoBrowserViewModel.process(scope:)`). The Mac import re-runs the rename with the real token,
/// which means re-supplying the sequence and batch that only exist in the current name: the sequence
/// came from the camera's original filename, long since replaced, and the batch was a per-session
/// label typed on the iPad. Everything else (`capturedAt`, camera, lens) is re-read from the file.
///
/// Kept pure and separate from the import service so it's unit testable without a real file,
/// mirroring `ArtFilterTokenParsing`'s split from `ExifToolClient`.
public enum IPadExportNameParsing {
    public struct Parsed: Equatable {
        /// Digits the camera burned into the original filename, `RenameService`'s first segment.
        public var sequence: String
        /// The per-session label, empty when none was set.
        public var batch: String

        public init(sequence: String, batch: String) {
            self.sequence = sequence
            self.batch = batch
        }
    }

    /// Parses `sequence_[batch_]YYYYMMDD_HHMM[_artfilter]_camera_lens.ext` — see
    /// `RenameService.buildFilename`. Returns `nil` for anything that isn't shaped like a name this
    /// app produced, which the caller reports as a skip rather than guessing at.
    ///
    /// The batch is whatever sits between the sequence and the date/time pair, so it's recovered by
    /// locating that pair rather than by counting segments — a batch label may itself contain `_`,
    /// which `RenameService.sanitizeComponent` doesn't strip. The one ambiguity this can't resolve:
    /// a batch label that *is* an 8-digit segment followed by a 4-digit one would be mistaken for
    /// the date/time pair, and the real pair read as part of the trailing camera/lens segments.
    public static func parse(filename: String) -> Parsed? {
        let stem = (filename as NSString).deletingPathExtension
        let parts = stem.components(separatedBy: "_")
        guard let sequence = parts.first, !sequence.isEmpty, sequence.allSatisfy(\.isNumber) else {
            return nil
        }

        guard let dateIndex = (1..<max(parts.count - 1, 1)).first(where: { isDateTimePair(parts, at: $0) })
        else { return nil }

        return Parsed(sequence: sequence, batch: parts[1..<dateIndex].joined(separator: "_"))
    }

    /// `RenameService.dateTimeParts` emits either `yyyyMMdd`/`HHmm` or the literal
    /// `UnknownDate`/`UnknownTime` pair when the file had no readable capture timestamp — both are
    /// valid anchors, since a file with an unreadable date still needs to be importable.
    private static func isDateTimePair(_ parts: [String], at index: Int) -> Bool {
        let date = parts[index]
        let time = parts[index + 1]
        if date.count == 8, date.allSatisfy(\.isNumber), time.count == 4, time.allSatisfy(\.isNumber) {
            return true
        }
        return date == "UnknownDate" && time == "UnknownTime"
    }
}
