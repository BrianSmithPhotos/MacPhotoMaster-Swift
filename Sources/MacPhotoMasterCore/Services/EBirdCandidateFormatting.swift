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

    /// Like `buildCandidateList` but common names only (no "(Scientific name)"), roughly halving the
    /// prompt size — for small on-device models where the full list bloats the prompt and slows
    /// generation. Safe to drop the scientific names from the prompt because the binomial is attached
    /// afterward by `attachScientificNames`, a deterministic lookup rather than something the model
    /// has to reproduce.
    public static func buildCommonNameList(
        speciesCodes: [String], taxonomy: [EBirdTaxonEntry], limit: Int
    ) -> String {
        let codeSet = Set(speciesCodes)
        let matched = taxonomy.filter { codeSet.contains($0.speciesCode) && $0.category == "species" }
        return matched.sorted { $0.commonName < $1.commonName }
            .prefix(limit)
            .map(\.commonName)
            .joined(separator: ", ")
    }

    /// Lowercased common name -> scientific name, for the region's real species — the lookup table
    /// used to attach a Latin binomial to whatever common name the model produced, deterministically,
    /// rather than relying on a small model to recall/format it (which it does unreliably).
    public static func scientificNameByCommonName(
        speciesCodes: [String], taxonomy: [EBirdTaxonEntry]
    ) -> [String: String] {
        let codeSet = Set(speciesCodes)
        var map: [String: String] = [:]
        for entry in taxonomy where codeSet.contains(entry.speciesCode) && entry.category == "species" {
            map[entry.commonName.lowercased()] = entry.scientificName
        }
        return map
    }

    /// Attaches Latin binomials to whatever species the model actually identified, deterministically.
    /// Searches the model's `description` and the user's `trustedKeywords` (their pre-existing,
    /// hand-confirmed keywords) for region-species common names — as a **whole word**,
    /// case-insensitively. For every match, the scientific name is appended to `keywords`; and the
    /// first (longest, most specific) common name found in the *description* also gets its binomial
    /// inserted inline (" (Scientific name)"). De-duplicated against existing keywords.
    ///
    /// The model's own freshly-generated `keywords` are deliberately **not** searched: a small model
    /// given a long candidate list will sometimes drop a list species into its keywords that isn't the
    /// actual subject (an unidentified heron once picked up "Acorn Woodpecker"), and certifying that
    /// with a binomial would launder a hallucination into authoritative-looking metadata. Only the
    /// description (the model's stated ID) and the user's trusted keywords drive matching.
    ///
    /// Whole-word matching is likewise load-bearing: substring matching once inserted a wrong binomial
    /// (a short common name hiding inside other prose). If the model used a descriptive phrase ("white
    /// egret") rather than an exact common name ("Great Egret"), nothing matches — a safe miss, never a
    /// wrong hit.
    public static func attachScientificNames(
        description: String, keywords: [String], trustedKeywords: [String],
        scientificNameByCommonName: [String: String]
    ) -> (description: String, keywords: [String]) {
        guard !scientificNameByCommonName.isEmpty else { return (description, keywords) }
        let commonNamesLongestFirst = scientificNameByCommonName.keys.sorted { $0.count > $1.count }
        let searchText = ([description] + trustedKeywords).joined(separator: "\n")

        var newDescription = description
        var newKeywords = keywords
        var descriptionInsertionDone = false

        for commonName in commonNamesLongestFirst {
            guard let scientificName = scientificNameByCommonName[commonName] else { continue }
            // Trailing `s?` lets a plural/flock mention ("Ruddy Turnstones", "Mallards") match the
            // singular eBird common name; still whole-word anchored, so no substring false matches.
            let wholeWord = "\\b" + NSRegularExpression.escapedPattern(for: commonName) + "s?\\b"
            guard searchText.range(of: wholeWord, options: [.regularExpression, .caseInsensitive]) != nil
            else { continue }

            if !newKeywords.contains(where: { $0.caseInsensitiveCompare(scientificName) == .orderedSame }) {
                newKeywords.append(scientificName)
            }

            if !descriptionInsertionDone,
                newDescription.range(of: scientificName, options: .caseInsensitive) == nil,
                let range = newDescription.range(
                    of: wholeWord, options: [.regularExpression, .caseInsensitive])
            {
                newDescription.insert(contentsOf: " (\(scientificName))", at: range.upperBound)
                descriptionInsertionDone = true
            }
        }
        return (newDescription, newKeywords)
    }
}
