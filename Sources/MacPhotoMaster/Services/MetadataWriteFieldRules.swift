import Foundation

/// Field rules shared by every `MetadataWriter` conformance — the same idempotent-keyword and
/// GPS-range rules apply whether the write lands directly in the file (`ExifToolClient`) or in a
/// sidecar (`NativeMetadataWriter`), so both call these rather than each keeping their own copy.
enum MetadataWriteFieldRules {
    static func validate(gps: GPSCoordinate?) throws {
        guard let gps else { return }
        guard (-90...90).contains(gps.latitude) else { throw MetadataWriteError.invalidLatitude(gps.latitude) }
        guard (-180...180).contains(gps.longitude) else { throw MetadataWriteError.invalidLongitude(gps.longitude) }
    }

    /// Trims, drops blanks, and dedupes case-insensitively (keeping the first-seen casing) so
    /// re-saving the same keyword list twice — or a list with only casing differences — doesn't
    /// grow the file's keyword tag on every save.
    static func normalizedKeywords(_ keywords: [String]) -> [String] {
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
