import Foundation

/// Pure, network/database-free helpers for turning eBird data into what
/// `AISuggestionService.buildUserPrompt` actually needs: a county name resolved to eBird's opaque
/// region code, and a capped candidate-list string. Split out from `EBirdSpeciesListService`/
/// `EBirdCache` so this formatting logic can be unit-tested without mocking a network or a GRDB
/// database.
public enum EBirdCandidateFormatting {
    private static let strippedSuffixes = [" county", " parish", " borough"]

    /// Matches a reverse-geocoded county name (e.g. "Marin County") against eBird's subnational2
    /// region list for the parent state, stripping the common US county-equivalent suffixes
    /// case-insensitively before comparing, since eBird's `name` field omits them (e.g. "Marin", not
    /// "Marin County").
    public static func matchRegion(
        countyName: String, in regions: [EBirdSubnationalRegion]
    ) -> EBirdSubnationalRegion? {
        let normalizedTarget = normalize(countyName)
        guard !normalizedTarget.isEmpty else { return nil }
        return regions.first { normalize($0.name) == normalizedTarget }
    }

    private static func normalize(_ name: String) -> String {
        var lowercased = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in strippedSuffixes where lowercased.hasSuffix(suffix) {
            lowercased.removeLast(suffix.count)
        }
        return lowercased.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the "Common Name (Genus species)" candidate list `AISuggestionService` appends to its
    /// prompt — filtered to real, nameable species (`category == "species"`), sorted alphabetically
    /// by common name for a deterministic/reviewable prompt, and capped at `limit` entries as a
    /// safety valve against prompt-token growth (a state-level fallback region list can exceed 1,000
    /// species codes; see `docs/MLX_PROVIDER.md`/CLAUDE.md hardware notes for why local-model context
    /// size is worth protecting).
    public static func buildCandidateList(
        speciesCodes: [String], taxonomy: [EBirdTaxonEntry], limit: Int
    ) -> String {
        let codeSet = Set(speciesCodes)
        let matched = taxonomy.filter { codeSet.contains($0.speciesCode) && $0.category == "species" }
        let sorted = matched.sorted { $0.commonName < $1.commonName }
        return sorted.prefix(limit)
            .map { "\($0.commonName) (\($0.scientificName))" }
            .joined(separator: ", ")
    }
}
