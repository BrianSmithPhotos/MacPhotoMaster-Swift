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
}
