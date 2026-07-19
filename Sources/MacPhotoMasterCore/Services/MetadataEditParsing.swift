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
