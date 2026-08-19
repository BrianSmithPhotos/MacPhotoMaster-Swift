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

    /// The three shapes a Timeline timestamp comes in, tried in order. Built once and reused: an
    /// export has one record per timestamp and building a formatter costs far more than parsing with
    /// one, so allocating per record turned a 13 MB export into a 50-second parse. Date formatters
    /// are safe to share as long as nothing mutates them after setup, which nothing here does.
    private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetDateTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let assumedUTCFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// Parses Timeline JSON timestamp text into UTC epoch seconds. When no offset is present,
    /// UTC is assumed — matching the reference app's `_parse_iso_timestamp` fallback.
    ///
    /// The hand-rolled scanner comes first because there is one timestamp per record and a real
    /// export has hundreds of thousands of them: `ISO8601DateFormatter.date(from:)` measures at
    /// ~63 microseconds a call, which is 6 seconds per 100k records, and the import runs before the
    /// user can do anything with GPS. The formatters stay as the fallback for any shape the scanner
    /// does not recognise, so nothing that used to parse stops parsing.
    private static func parseISOTimestamp(_ timestampText: String) -> Int? {
        let trimmed = timestampText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let epochSeconds = epochSecondsScanningISO8601(trimmed) { return epochSeconds }

        if let date = fractionalSecondsFormatter.date(from: trimmed) {
            return Int(date.timeIntervalSince1970)
        }
        if let date = internetDateTimeFormatter.date(from: trimmed) {
            return Int(date.timeIntervalSince1970)
        }
        if let date = assumedUTCFormatter.date(from: trimmed) {
            return Int(date.timeIntervalSince1970)
        }
        return nil
    }

    /// `YYYY-MM-DDTHH:MM:SS`, optionally `.fff`, optionally `Z` or `+/-HH:MM` — the shapes Google
    /// actually writes. Anything else returns nil and the formatters get their turn. Fractional
    /// seconds are read past rather than used, matching the truncation the formatter path does.
    private static func epochSecondsScanningISO8601(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 19 else { return nil }

        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for index in start..<(start + count) {
                let byte = bytes[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        func isByte(_ index: Int, _ character: Unicode.Scalar) -> Bool {
            bytes[index] == UInt8(ascii: character)
        }

        guard isByte(4, "-"), isByte(7, "-"), isByte(10, "T") || isByte(10, " "),
            isByte(13, ":"), isByte(16, ":"),
            let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
            let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
            month >= 1, month <= 12, day >= 1, day <= 31, hour <= 23, minute <= 59, second <= 60
        else { return nil }

        var index = 19
        if index < bytes.count, isByte(index, ".") {
            index += 1
            let fractionStart = index
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                index += 1
            }
            guard index > fractionStart else { return nil }
        }

        var offsetSeconds = 0
        if index < bytes.count {
            if isByte(index, "Z") || isByte(index, "z") {
                index += 1
            } else if isByte(index, "+") || isByte(index, "-") {
                let sign = isByte(index, "-") ? -1 : 1
                guard bytes.count >= index + 6, isByte(index + 3, ":"),
                    let offsetHours = digits(index + 1, 2), let offsetMinutes = digits(index + 4, 2)
                else { return nil }
                offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
                index += 6
            }
        }
        guard index == bytes.count else { return nil }

        return daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second - offsetSeconds
    }

    /// Days between 1970-01-01 and the given date, by Howard Hinnant's civil-from-days algorithm —
    /// calendar arithmetic without a `Calendar`, which is the other Foundation call that would cost
    /// more than the whole parse.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = year - (month <= 2 ? 1 : 0)
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
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
