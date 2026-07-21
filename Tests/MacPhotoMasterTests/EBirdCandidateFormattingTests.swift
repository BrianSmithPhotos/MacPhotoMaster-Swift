import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class EBirdCandidateFormattingTests: XCTestCase {
    // MARK: - matchRegion

    func testMatchRegionStripsCountySuffixCaseInsensitively() {
        let regions = [
            EBirdSubnationalRegion(code: "US-CA-041", name: "Marin"),
            EBirdSubnationalRegion(code: "US-CA-075", name: "San Francisco"),
        ]

        let match = EBirdCandidateFormatting.matchRegion(countyName: "Marin County", in: regions)

        XCTAssertEqual(match, EBirdSubnationalRegion(code: "US-CA-041", name: "Marin"))
    }

    func testMatchRegionStripsParishAndBoroughSuffixes() {
        let regions = [
            EBirdSubnationalRegion(code: "US-LA-071", name: "Orleans"),
            EBirdSubnationalRegion(code: "US-AK-020", name: "Anchorage"),
        ]

        XCTAssertEqual(
            EBirdCandidateFormatting.matchRegion(countyName: "Orleans Parish", in: regions)?.code,
            "US-LA-071")
        XCTAssertEqual(
            EBirdCandidateFormatting.matchRegion(countyName: "Anchorage Borough", in: regions)?.code,
            "US-AK-020")
    }

    func testMatchRegionReturnsNilWhenNoNameMatches() {
        let regions = [EBirdSubnationalRegion(code: "US-CA-041", name: "Marin")]

        let match = EBirdCandidateFormatting.matchRegion(countyName: "Sonoma County", in: regions)

        XCTAssertNil(match)
    }

    func testMatchRegionReturnsNilForEmptyCountyName() {
        let regions = [EBirdSubnationalRegion(code: "US-CA-041", name: "Marin")]

        let match = EBirdCandidateFormatting.matchRegion(countyName: "   ", in: regions)

        XCTAssertNil(match)
    }

    // MARK: - buildCandidateList

    func testBuildCandidateListFormatsCommonAndScientificName() {
        let taxonomy = [
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species")
        ]

        let list = EBirdCandidateFormatting.buildCandidateList(
            speciesCodes: ["comrav"], taxonomy: taxonomy, limit: 10)

        XCTAssertEqual(list, "Common Raven (Corvus corax)")
    }

    func testBuildCandidateListExcludesNonSpeciesCategories() {
        let taxonomy = [
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species"),
            EBirdTaxonEntry(
                speciesCode: "x00776", commonName: "goose sp.", scientificName: "Anser sp.",
                category: "spuh"),
        ]

        let list = EBirdCandidateFormatting.buildCandidateList(
            speciesCodes: ["comrav", "x00776"], taxonomy: taxonomy, limit: 10)

        XCTAssertEqual(list, "Common Raven (Corvus corax)")
    }

    func testBuildCandidateListExcludesCodesNotInRegionList() {
        let taxonomy = [
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species"),
            EBirdTaxonEntry(
                speciesCode: "houfin", commonName: "House Finch", scientificName: "Haemorhous mexicanus",
                category: "species"),
        ]

        let list = EBirdCandidateFormatting.buildCandidateList(
            speciesCodes: ["comrav"], taxonomy: taxonomy, limit: 10)

        XCTAssertEqual(list, "Common Raven (Corvus corax)")
    }

    func testBuildCandidateListSortsAlphabeticallyByCommonName() {
        let taxonomy = [
            EBirdTaxonEntry(
                speciesCode: "houfin", commonName: "House Finch", scientificName: "Haemorhous mexicanus",
                category: "species"),
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species"),
        ]

        let list = EBirdCandidateFormatting.buildCandidateList(
            speciesCodes: ["houfin", "comrav"], taxonomy: taxonomy, limit: 10)

        XCTAssertEqual(list, "Common Raven (Corvus corax), House Finch (Haemorhous mexicanus)")
    }

    func testBuildCandidateListRespectsLimit() {
        let taxonomy = [
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species"),
            EBirdTaxonEntry(
                speciesCode: "houfin", commonName: "House Finch", scientificName: "Haemorhous mexicanus",
                category: "species"),
        ]

        let list = EBirdCandidateFormatting.buildCandidateList(
            speciesCodes: ["comrav", "houfin"], taxonomy: taxonomy, limit: 1)

        XCTAssertEqual(list, "Common Raven (Corvus corax)")
    }

    func testBuildCandidateListReturnsEmptyStringForEmptyInput() {
        let list = EBirdCandidateFormatting.buildCandidateList(
            speciesCodes: [], taxonomy: [], limit: 10)

        XCTAssertEqual(list, "")
    }

    // MARK: - buildCommonNameList

    func testBuildCommonNameListOmitsScientificNames() {
        let taxonomy = [
            EBirdTaxonEntry(
                speciesCode: "comrav", commonName: "Common Raven", scientificName: "Corvus corax",
                category: "species"),
            EBirdTaxonEntry(
                speciesCode: "houfin", commonName: "House Finch", scientificName: "Haemorhous mexicanus",
                category: "species"),
        ]

        let list = EBirdCandidateFormatting.buildCommonNameList(
            speciesCodes: ["comrav", "houfin"], taxonomy: taxonomy, limit: 10)

        XCTAssertEqual(list, "Common Raven, House Finch")
    }

    // MARK: - scientificNameByCommonName / attachScientificNames

    private static let heronTaxonomy = [
        EBirdTaxonEntry(
            speciesCode: "grbher3", commonName: "Great Blue Heron", scientificName: "Ardea herodias",
            category: "species"),
        EBirdTaxonEntry(
            speciesCode: "categr", commonName: "Great Egret", scientificName: "Ardea alba",
            category: "species"),
        EBirdTaxonEntry(
            speciesCode: "grnher", commonName: "Green Heron", scientificName: "Butorides virescens",
            category: "species"),
        EBirdTaxonEntry(
            speciesCode: "acowoo", commonName: "Acorn Woodpecker",
            scientificName: "Melanerpes formicivorus", category: "species"),
        EBirdTaxonEntry(
            speciesCode: "x00776", commonName: "heron sp.", scientificName: "Ardea sp.", category: "spuh"),
    ]

    private static var heronMap: [String: String] {
        EBirdCandidateFormatting.scientificNameByCommonName(
            speciesCodes: ["grbher3", "categr", "grnher", "acowoo", "x00776"], taxonomy: heronTaxonomy)
    }

    func testScientificNameMapLowercasesKeysAndExcludesNonSpecies() {
        let map = Self.heronMap
        XCTAssertEqual(map["great blue heron"], "Ardea herodias")
        XCTAssertEqual(map["great egret"], "Ardea alba")
        XCTAssertNil(map["heron sp."])  // "spuh" category excluded
    }

    func testAttachInsertsBinomialInDescriptionAndKeyword() {
        let result = EBirdCandidateFormatting.attachScientificNames(
            description: "A Great Blue Heron wades in the shallows.", keywords: ["heron", "water"],
            trustedKeywords: [], scientificNameByCommonName: Self.heronMap)

        XCTAssertEqual(result.description, "A Great Blue Heron (Ardea herodias) wades in the shallows.")
        XCTAssertTrue(result.keywords.contains("Ardea herodias"))
    }

    func testAttachWholeWordMatchingAvoidsWrongBinomial() {
        // The reason this exists: substring matching once turned an egret into "Branta bernicla".
        // A common name must match as a whole word, not as a fragment hiding in other text.
        let map = ["ant": "Formica sp."]  // "ant" must NOT match inside "elegant"
        let result = EBirdCandidateFormatting.attachScientificNames(
            description: "An elegant white bird stands in the marsh.", keywords: [], trustedKeywords: [],
            scientificNameByCommonName: map)

        XCTAssertEqual(result.description, "An elegant white bird stands in the marsh.")
        XCTAssertFalse(result.keywords.contains("Formica sp."))
    }

    func testAttachHandlesMultipleSpeciesFromDescriptionAndTrustedKeywords() {
        // One heron in the description, another the user named in their (trusted) keywords — both get
        // their binomial as a keyword.
        let result = EBirdCandidateFormatting.attachScientificNames(
            description: "A Great Blue Heron by the pond.", keywords: ["pond"],
            trustedKeywords: ["Green Heron"], scientificNameByCommonName: Self.heronMap)

        XCTAssertTrue(result.keywords.contains("Ardea herodias"))
        XCTAssertTrue(result.keywords.contains("Butorides virescens"))
    }

    func testAttachIgnoresModelGeneratedKeywords() {
        // The Acorn Woodpecker case: the model hallucinated a candidate species into ITS keywords for
        // an unidentified brown heron. Those must not be searched, or a hallucination gets a binomial.
        let result = EBirdCandidateFormatting.attachScientificNames(
            description: "A brown heron stands in the reeds.", keywords: ["Acorn Woodpecker", "bird"],
            trustedKeywords: [], scientificNameByCommonName: Self.heronMap)

        XCTAssertFalse(result.description.contains("Melanerpes"))
        XCTAssertFalse(result.keywords.contains("Melanerpes formicivorus"))
    }

    func testAttachMatchesPluralCommonName() {
        // "Ruddy Turnstones" (a flock) must still match the singular eBird name "Ruddy Turnstone".
        let result = EBirdCandidateFormatting.attachScientificNames(
            description: "A flock of Ruddy Turnstones on the rocks.", keywords: [], trustedKeywords: [],
            scientificNameByCommonName: ["ruddy turnstone": "Arenaria interpres"])

        XCTAssertEqual(
            result.description, "A flock of Ruddy Turnstones (Arenaria interpres) on the rocks.")
        XCTAssertTrue(result.keywords.contains("Arenaria interpres"))
    }

    func testAttachPrefersLongestCommonNameForDescriptionInsertion() {
        let map = ["heron": "Ardeidae", "great blue heron": "Ardea herodias"]
        let result = EBirdCandidateFormatting.attachScientificNames(
            description: "A Great Blue Heron.", keywords: [], trustedKeywords: [],
            scientificNameByCommonName: map)

        XCTAssertEqual(result.description, "A Great Blue Heron (Ardea herodias).")
    }

    func testAttachNoOpWhenBinomialAlreadyInDescription() {
        let original = "A Great Blue Heron (Ardea herodias) already named."
        let result = EBirdCandidateFormatting.attachScientificNames(
            description: original, keywords: [], trustedKeywords: [],
            scientificNameByCommonName: Self.heronMap)

        XCTAssertEqual(result.description, original)
    }

    func testAttachNoOpWhenNoCommonNameFound() {
        let result = EBirdCandidateFormatting.attachScientificNames(
            description: "A wooden bridge over a river.", keywords: ["bridge"], trustedKeywords: [],
            scientificNameByCommonName: Self.heronMap)

        XCTAssertEqual(result.description, "A wooden bridge over a river.")
        XCTAssertEqual(result.keywords, ["bridge"])
    }
}
