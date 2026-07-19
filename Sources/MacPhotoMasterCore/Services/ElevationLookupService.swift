import Foundation

public enum ElevationLookupError: Error {
    case requestFailed(Error)
    case noUsableValue
}

/// Ground-elevation lookup via USGS EPQS, keyed by lat/lon — see docs/SPEC.md §7: Timeline's own
/// phone-GPS altitude is untrusted, so altitude always comes from here instead. Mirrors the
/// reference app's `ElevationLookupService`. First `URLSession` usage in this codebase.
public struct ElevationLookupService {
    private static let baseURL = URL(string: "https://epqs.nationalmap.gov/v1/json")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lookupElevation(latitude: Double, longitude: Double) async throws -> Double {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "x", value: String(format: "%.7f", longitude)),
            URLQueryItem(name: "y", value: String(format: "%.7f", latitude)),
            URLQueryItem(name: "units", value: "Meters"),
            URLQueryItem(name: "wkid", value: "4326"),
            URLQueryItem(name: "includeDate", value: "false"),
        ]

        let data: Data
        do {
            (data, _) = try await session.data(from: components.url!)
        } catch {
            throw ElevationLookupError.requestFailed(error)
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = Self.extractValue(from: payload)
        else {
            throw ElevationLookupError.noUsableValue
        }
        return value
    }

    /// Handles the handful of known EPQS response shapes the reference app defends against.
    public static func extractValue(from payload: [String: Any]) -> Double? {
        if let direct = toDouble(payload["value"]) {
            return direct
        }
        if let nested = payload["USGS_Elevation_Point_Query_Service"] as? [String: Any],
            let elevationQuery = nested["Elevation_Query"] as? [String: Any],
            let elevation = toDouble(elevationQuery["Elevation"])
        {
            return elevation
        }
        if let elevation = toDouble(payload["elevation"]) {
            return elevation
        }
        return nil
    }

    private static func toDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }
}
