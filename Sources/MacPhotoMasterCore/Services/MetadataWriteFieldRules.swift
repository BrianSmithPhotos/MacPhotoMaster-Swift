import Foundation

/// Field rules shared by every `MetadataWriter` conformance — the same idempotent-keyword and
/// GPS-range rules apply whether the write lands directly in the file (`ExifToolClient`) or in a
/// sidecar (`NativeMetadataWriter`), so both call these rather than each keeping their own copy.
public enum MetadataWriteFieldRules {
    public static func validate(gps: GPSCoordinate?) throws {
        guard let gps else { return }
        guard (-90...90).contains(gps.latitude) else { throw MetadataWriteError.invalidLatitude(gps.latitude) }
        guard (-180...180).contains(gps.longitude) else { throw MetadataWriteError.invalidLongitude(gps.longitude) }
    }

    /// Parses the display-formatted focus-distance string this app reads for the UI (exiftool's
    /// `Olympus:FocusDistance`, e.g. `"16.03 m"`) into a plain metre value for the standard
    /// `EXIF:SubjectDistance` tag. Returns `nil` for anything that isn't a usable finite positive
    /// distance — a blank field, an `"inf"` reading (focused at infinity), or a `0` — so those never
    /// get written out as a bogus fixed distance. The leading token is parsed with `Double`'s own
    /// C-locale init, matching exiftool's always-dot decimal formatting.
    public static func subjectDistanceMeters(from displayString: String) -> Double? {
        let token = displayString.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let value = Double(token), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Trims, drops blanks, and dedupes case-insensitively (keeping the first-seen casing) so
    /// re-saving the same keyword list twice — or a list with only casing differences — doesn't
    /// grow the file's keyword tag on every save.
    public static func normalizedKeywords(_ keywords: [String]) -> [String] {
        var seenLowercased = Set<String>()
        var result: [String] = []
        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seenLowercased.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
