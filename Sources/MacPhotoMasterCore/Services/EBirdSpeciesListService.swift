import Foundation

public enum EBirdError: Error {
    case missingAPIKey
    case requestFailed(Error)
    case invalidResponse
}

/// One row of eBird's global taxonomy — `category` distinguishes real, identifiable species
/// ("species") from "spuh"/"slash"/"hybrid"/"domestic"/"form"/"issf"/"intergrade" entries that
/// `EBirdCandidateFormatting` filters out before building a prompt candidate list, since those
/// aren't things a description should ever name (e.g. "goose sp." or a domestic/feral form).
public struct EBirdTaxonEntry: Equatable {
    public var speciesCode: String
    public var commonName: String
    public var scientificName: String
    public var category: String
}

/// One eBird subnational2 (county-equivalent) region, as returned by the subnational2 region list
/// for a given subnational1 (state/province) parent — used to resolve a reverse-geocoded county
/// name to the region code `spplist` needs, since eBird's county-level codes are opaque FIPS-style
/// strings (e.g. `"US-CA-041"` for Marin) that can't be derived from the name alone.
public struct EBirdSubnationalRegion: Equatable {
    public var code: String
    public var name: String
}

/// Thin client for the three eBird API (api.ebird.org) endpoints `EBirdCache`/
/// `SourceBrowserViewModel` need to build a location-based bird candidate list — see
/// `AISuggestionService`'s doc comment for why: giving a VLM a verified local species list to
/// select from, rather than free recall, is the fix for observed fabricated/garbled Latin
/// binomials on genuinely uncertain photos. No caching here (that's `EBirdCache`'s job) — this
/// struct only knows how to make the three requests and parse their responses.
public struct EBirdSpeciesListService {
    private static let baseURL = URL(string: "https://api.ebird.org/v2")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// `EBIRD_API_KEY` env var wins if set (terminal/`swift run` debugging), else the value saved
    /// in `SettingsView`'s API Keys section (Keychain-backed) — see `APIKeyStore`.
    private static var apiKey: String? {
        APIKeyStore.resolve(envVar: "EBIRD_API_KEY", account: "EBIRD_API_KEY")
    }

    /// eBird's full global taxonomy (~18,000 rows, ~6MB of JSON as of this writing) — fetched in
    /// full since there's no per-species-code batch lookup endpoint; `EBirdCache` persists this so
    /// it's only re-fetched when stale, not on every suggestion.
    public func fetchTaxonomy() async throws -> [EBirdTaxonEntry] {
        let url = Self.baseURL.appendingPathComponent("ref/taxonomy/ebird")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fmt", value: "json")]
        let data = try await get(components.url!)

        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EBirdError.invalidResponse
        }
        return rows.compactMap { row in
            guard let speciesCode = row["speciesCode"] as? String,
                let commonName = row["comName"] as? String,
                let scientificName = row["sciName"] as? String,
                let category = row["category"] as? String
            else { return nil }
            return EBirdTaxonEntry(
                speciesCode: speciesCode, commonName: commonName, scientificName: scientificName,
                category: category)
        }
    }

    /// The counties/county-equivalents of `parentCode` (a subnational1 code, e.g. `"US-CA"`) — a
    /// short, effectively-static list (California has 58 entries), used once per state to resolve
    /// a county name to its eBird region code.
    public func fetchSubnational2Regions(parentCode: String) async throws -> [EBirdSubnationalRegion] {
        let url = Self.baseURL.appendingPathComponent("ref/region/list/subnational2/\(parentCode)")
        let data = try await get(url)

        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EBirdError.invalidResponse
        }
        return rows.compactMap { row in
            guard let code = row["code"] as? String, let name = row["name"] as? String else {
                return nil
            }
            return EBirdSubnationalRegion(code: code, name: name)
        }
    }

    /// All species codes ever recorded in `regionCode` (any eBird region level — country,
    /// subnational1, or subnational2) — no date/recency filtering, unlike eBird's "recent
    /// observations" endpoint, which is the whole point: a full regional species pool, not just
    /// what happened to be logged in the last 30 days.
    public func fetchSpeciesCodes(regionCode: String) async throws -> [String] {
        let url = Self.baseURL.appendingPathComponent("product/spplist/\(regionCode)")
        let data = try await get(url)

        guard let codes = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw EBirdError.invalidResponse
        }
        return codes
    }

    private func get(_ url: URL) async throws -> Data {
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else { throw EBirdError.missingAPIKey }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-eBirdApiToken")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200
            else { throw EBirdError.invalidResponse }
            return data
        } catch let error as EBirdError {
            throw error
        } catch {
            throw EBirdError.requestFailed(error)
        }
    }
}
