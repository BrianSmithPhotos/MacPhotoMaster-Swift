import Foundation

/// Pure helpers for turning the metadata panel's free-text edit buffer into the typed values
/// `ExifToolClient.write` needs. Kept separate from `SourceBrowserViewModel` so this logic is unit
/// testable without a live view model — mirrors `SelectionScope`'s split.
public enum MetadataEditParsing {
    /// Splits a comma-separated keyword field into trimmed, non-empty entries. `ExifToolClient`
    /// still does its own trim/dedupe pass before writing (see its `normalizedKeywords`), so this
    /// only needs to handle the splitting.
    public static func parseKeywords(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The keywords in the edit buffer that weren't loaded from the file — what the user typed (or
    /// what a reverse-geocode lookup merged in) since the photo was selected. An AI suggestion
    /// replaces the whole keyword field with the model's own list, so these need re-attaching
    /// afterwards: the prompt asks the model to treat existing keywords as a trusted guide, but
    /// that's compliance, not a guarantee — small on-device models routinely ignore it and drop a
    /// hint the user typed specifically to steer the identification.
    ///
    /// Case-insensitive, and keeps the buffer's own order.
    public static func userAddedKeywords(current: [String], loaded: [String]) -> [String] {
        let loadedLowercased = Set(loaded.map { $0.lowercased() })
        return current.filter { !loadedLowercased.contains($0.lowercased()) }
    }

    /// Puts `userAdded` back at the front of an AI suggestion's keyword list — most
    /// specific/identifying first, same ordering rule the prompt gives the model — skipping any the
    /// model already produced.
    public static func merging(userAdded: [String], into keywords: [String]) -> [String] {
        let existing = Set(keywords.map { $0.lowercased() })
        return userAdded.filter { !existing.contains($0.lowercased()) } + keywords
    }

    /// Parses the latitude/longitude text fields into a `GPSCoordinate`, reusing `altitude` from
    /// whatever the asset already has (the edit form has no altitude field — that's populated by
    /// Timeline/elevation lookups, not typed in, per docs/SPEC.md §7). Either field blank or
    /// unparseable as a number means "don't touch GPS" rather than "clear it" — `nil` here is what
    /// tells `ExifToolClient.write` to omit the GPS arguments entirely, leaving any existing GPS
    /// tag on disk untouched.
    public static func parseGPS(latitudeText: String, longitudeText: String, altitude: Double?) -> GPSCoordinate? {
        let trimmedLatitude = latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLongitude = longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLatitude.isEmpty, !trimmedLongitude.isEmpty,
            let latitude = Double(trimmedLatitude), let longitude = Double(trimmedLongitude)
        else { return nil }
        return GPSCoordinate(latitude: latitude, longitude: longitude, altitude: altitude)
    }
}
