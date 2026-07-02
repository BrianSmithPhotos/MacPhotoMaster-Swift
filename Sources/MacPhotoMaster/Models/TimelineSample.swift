import CryptoKit
import Foundation

/// One normalized Google Timeline position sample, ready to cache locally for nearest-timestamp
/// GPS matching. Mirrors the reference app's `_TimelinePosition` (see docs/SPEC.md §7) — parsing
/// a raw Timeline JSON export into these is a separate concern from caching/matching them.
struct TimelineSample: Equatable {
    var recordKey: String
    var timestampUTC: Int
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var accuracyMeters: Double?
    var sourceType: String

    /// Deterministic hash key so re-importing the same Timeline export upserts rather than
    /// duplicates. Matches the reference app's `_build_record_key` field order/precision exactly
    /// so the two apps would derive the same key for the same source record (not that they share
    /// a database — this just keeps the two implementations easy to compare).
    static func recordKey(
        timestampUTC: Int,
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double?,
        sourceType: String,
        accuracyMeters: Double?
    ) -> String {
        let altitudeText = altitudeMeters.map { String(format: "%.3f", $0) } ?? ""
        let accuracyText = accuracyMeters.map { String(format: "%.3f", $0) } ?? ""
        let raw =
            "\(timestampUTC)|\(String(format: "%.7f", latitude))|\(String(format: "%.7f", longitude))|"
            + "\(altitudeText)|\(sourceType)|\(accuracyText)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// GPS match returned for one photo capture timestamp. Mirrors the reference app's
/// `GpsSuggestion`.
struct GPSSuggestion: Equatable {
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var sourceType: String
    var accuracyMeters: Double?
    var matchedTimestampUTC: Int
    var ageSeconds: Int
}
