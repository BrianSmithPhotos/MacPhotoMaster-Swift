import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Covers `SourceBrowserViewModel.derivativeSweep` — when a staged RAW derivative that has already
/// reached the library is allowed to be trashed. Getting this wrong is quiet in both directions:
/// sweeping too eagerly makes the frame the user just processed vanish from the grid instead of
/// showing its check mark, and never sweeping leaves a second copy of every developed frame in
/// application support forever.
@MainActor
final class SourceBrowserDerivativeSweepTests: XCTestCase {
    private let folder = "/Volumes/CARD/DCIM/100OLYMP"
    private let otherFolder = "/Volumes/CARD/DCIM/101OLYMP"

    private func raw(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/CARD/DCIM/100OLYMP/\(name)")
    }

    /// The reload immediately after a process. The derivative is spent by then, but it is also the
    /// tile the user is looking at, so it has to survive.
    func testDerivativeJustProcessedSurvivesAReloadOfItsOwnFolder() {
        let original = raw("P1010042.ORF")

        let result = SourceBrowserViewModel.derivativeSweep(
            loadingFolderPath: folder,
            keptFolderPath: folder,
            keptOriginals: [original],
            spentOriginalsInFolder: [original])

        XCTAssertTrue(result.discard.isEmpty)
        XCTAssertEqual(result.stillKept, [original])
    }

    func testNavigatingToAnotherFolderReleasesEverythingHeld() {
        let held: Set<URL> = [raw("P1010042.ORF"), raw("P1010043.ORF")]

        let result = SourceBrowserViewModel.derivativeSweep(
            loadingFolderPath: otherFolder,
            keptFolderPath: folder,
            keptOriginals: held,
            spentOriginalsInFolder: [])

        XCTAssertEqual(result.discard, held)
        XCTAssertTrue(result.stillKept.isEmpty)
    }

    /// The post-quit case: `keptDerivativeOriginals` lives only in memory, so a session that ended
    /// while holding leaves nothing behind to hold on its behalf. The spent derivative goes.
    func testSpentDerivativeNobodyIsHoldingIsSweptEvenInItsOwnFolder() {
        let original = raw("P1010042.ORF")

        let result = SourceBrowserViewModel.derivativeSweep(
            loadingFolderPath: folder,
            keptFolderPath: nil,
            keptOriginals: [],
            spentOriginalsInFolder: [original])

        XCTAssertEqual(result.discard, [original])
        XCTAssertTrue(result.stillKept.isEmpty)
    }

    /// Processing one frame of a folder that already had a stranded derivative from a previous
    /// session must sweep the stranger without touching the one just made.
    func testHeldAndStrandedDerivativesInTheSameFolderAreSeparated() {
        let justProcessed = raw("P1010042.ORF")
        let stranded = raw("P1010009.ORF")

        let result = SourceBrowserViewModel.derivativeSweep(
            loadingFolderPath: folder,
            keptFolderPath: folder,
            keptOriginals: [justProcessed],
            spentOriginalsInFolder: [justProcessed, stranded])

        XCTAssertEqual(result.discard, [stranded])
        XCTAssertEqual(result.stillKept, [justProcessed])
    }

    func testFolderWithNothingSpentAndNothingHeldSweepsNothing() {
        let result = SourceBrowserViewModel.derivativeSweep(
            loadingFolderPath: folder,
            keptFolderPath: nil,
            keptOriginals: [],
            spentOriginalsInFolder: [])

        XCTAssertTrue(result.discard.isEmpty)
        XCTAssertTrue(result.stillKept.isEmpty)
    }
}
