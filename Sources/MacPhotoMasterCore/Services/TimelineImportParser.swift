import Foundation

public enum TimelineImportError: Error {
    case unreadableFile
    case invalidJSON
    case noPositionRecords
}

/// Parses a raw Google Timeline JSON export into `TimelineSample` values ready for
/// `TimelineLocationCache.importSamples`. Mirrors the reference app's
/// `TimelineLocationService._parse_timeline_positions` (see docs/SPEC.md §7): `rawSignals.position`
/// entries are preferred because they carry accuracy/source/altitude; `semanticSegments`
/// `timelinePath` points fill gaps as coarser, sourceless `TIMELINE_PATH` samples. Uses
/// `JSONSerialization` rather than `Decodable` because real-world exports have inconsistent/missing
/// fields per record — a malformed or partial record is skipped, not treated as a parse failure.
public struct TimelineImportParser {
    public init() {}

    public func parseSamples(fromFileAt url: URL) throws -> [TimelineSample] {
        guard let data = try? Data(contentsOf: url) else {
            throw TimelineImportError.unreadableFile
        }
        return try parseSamples(from: data)
    }

    public func parseSamples(from data: Data) throws -> [TimelineSample] {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TimelineImportError.invalidJSON
        }

        var samples: [TimelineSample] = []
        var seenRecordKeys: Set<String> = []

        if let rawSignals = payload["rawSignals"] as? [[String: Any]] {
            for rawSignal in rawSignals {
                guard let position = rawSignal["position"] as? [String: Any],
                    let sample = Self.sample(fromRawSignalPosition: position)
                else {
                    continue
                }
                if seenRecordKeys.insert(sample.recordKey).inserted {
                    samples.append(sample)
                }
            }
        }

        if let semanticSegments = payload["semanticSegments"] as? [[String: Any]] {
            for segment in semanticSegments {
                guard let timelinePathPoints = segment["timelinePath"] as? [[String: Any]] else {
                    continue
                }
                for point in timelinePathPoints {
                    guard let sample = Self.sample(fromTimelinePathPoint: point) else { continue }
                    if seenRecordKeys.insert(sample.recordKey).inserted {
                        samples.append(sample)
                    }
                }
            }
        }

        guard !samples.isEmpty else {
            throw TimelineImportError.noPositionRecords
        }
        return samples
    }

    private static func sample(fromRawSignalPosition position: [String: Any]) -> TimelineSample? {
        let coordinateText = text(position["LatLng"])
        let timestampText = text(position["timestamp"])
        guard !coordinateText.isEmpty, !timestampText.isEmpty,
            let latLon = parseLatLon(coordinateText),
            let timestampUTC = parseISOTimestamp(timestampText)
        else {
            return nil
        }

        let altitudeMeters = optionalDouble(position["altitudeMeters"])
        let accuracyMeters = optionalDouble(position["accuracyMeters"])
        let sourceTypeRaw = text(position["source"]).trimmingCharacters(in: .whitespaces)
        let sourceType = sourceTypeRaw.isEmpty ? "UNKNOWN" : sourceTypeRaw

        return TimelineSample(
            recordKey: TimelineSample.recordKey(
                timestampUTC: timestampUTC, latitude: latLon.latitude, longitude: latLon.longitude,
                altitudeMeters: altitudeMeters, sourceType: sourceType, accuracyMeters: accuracyMeters),
            timestampUTC: timestampUTC, latitude: latLon.latitude, longitude: latLon.longitude,
            altitudeMeters: altitudeMeters, accuracyMeters: accuracyMeters, sourceType: sourceType)
    }

    private static func sample(fromTimelinePathPoint point: [String: Any]) -> TimelineSample? {
        let coordinateText = text(point["point"])
        let timestampText = text(point["time"])
        guard !coordinateText.isEmpty, !timestampText.isEmpty,
            let latLon = parseLatLon(coordinateText),
            let timestampUTC = parseISOTimestamp(timestampText)
        else {
            return nil
        }

        return TimelineSample(
            recordKey: TimelineSample.recordKey(
                timestampUTC: timestampUTC, latitude: latLon.latitude, longitude: latLon.longitude,
                altitudeMeters: nil, sourceType: "TIMELINE_PATH", accuracyMeters: nil),
            timestampUTC: timestampUTC, latitude: latLon.latitude, longitude: latLon.longitude,
            altitudeMeters: nil, accuracyMeters: nil, sourceType: "TIMELINE_PATH")
    }

    /// Parses Google Timeline's `"<lat>°, <lon>°"` coordinate text.
    private static func parseLatLon(_ coordinateText: String) -> (latitude: Double, longitude: Double)? {
        let cleaned = coordinateText.replacingOccurrences(of: "°", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1])
        else {
            return nil
        }
        return (latitude, longitude)
    }

    /// Parses Timeline JSON timestamp text into UTC epoch seconds. When no offset is present,
    /// UTC is assumed — matching the reference app's `_parse_iso_timestamp` fallback.
    private static func parseISOTimestamp(_ timestampText: String) -> Int? {
        let trimmed = timestampText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: trimmed) {
            return Int(date.timeIntervalSince1970)
        }

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        if let date = withoutFractionalSeconds.date(from: trimmed) {
            return Int(date.timeIntervalSince1970)
        }

        let assumedUTC = DateFormatter()
        assumedUTC.locale = Locale(identifier: "en_US_POSIX")
        assumedUTC.timeZone = TimeZone(identifier: "UTC")
        assumedUTC.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = assumedUTC.date(from: trimmed) {
            return Int(date.timeIntervalSince1970)
        }

        return nil
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let stringValue as String:
            return stringValue
        case let numberValue as NSNumber:
            return numberValue.stringValue
        default:
            return ""
        }
    }

    private static func optionalDouble(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
