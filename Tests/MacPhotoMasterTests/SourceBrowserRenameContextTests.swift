import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Covers `SourceBrowserViewModel.renameContext(for:batch:)` — the point where a RAW-developed
/// derivative's two filename rules are applied. Both are silent when wrong: the frame number just
/// comes out different, and the decoder token just goes missing.
@MainActor
final class SourceBrowserRenameContextTests: XCTestCase {
    private func makeDerived() -> PhotoAsset {
        // The name a `RawDerivedStore` key really produces: file size, then the original's full name.
        var asset = PhotoAsset(id: URL(fileURLWithPath: "/staging/19763130_P1066411.ORF.jpg"))
        asset.derivedFrom = URL(fileURLWithPath: "/card/DCIM/100OMSYS/P1066411.ORF")
        asset.keywords = ["RAW9"]
        asset.cameraModel = "OM-3"
        return asset
    }

    /// `RenameService.sequence(from:)` harvests every digit in the stem, so handing it the staging
    /// name would fold the file size into the frame number.
    func testDerivedAssetIsRenamedFromTheOriginalsNameNotItsStagingKey() {
        let context = SourceBrowserViewModel.renameContext(for: makeDerived(), batch: "SanRafael")

        XCTAssertEqual(context.sourceURL.lastPathComponent, "P1066411.jpg")
        // `sequence(from:)` is private, so this asserts through the filename it feeds.
        XCTAssertTrue(RenameService().buildFilename(for: context).hasPrefix("1066411_SanRafael_"))
    }

    func testDerivedAssetPutsTheDecoderTokenInTheArtFilterSlot() {
        let context = SourceBrowserViewModel.renameContext(for: makeDerived(), batch: "SanRafael")

        XCTAssertEqual(context.artFilterToken, "RAW9")
    }

    /// A camera file is untouched by any of this.
    func testCameraFileKeepsItsOwnNameAndArtFilterToken() {
        var asset = PhotoAsset(id: URL(fileURLWithPath: "/card/DCIM/P1066411.JPG"))
        asset.artFilterToken = "Grainy Film"

        let context = SourceBrowserViewModel.renameContext(for: asset, batch: "SanRafael")

        XCTAssertEqual(context.sourceURL, asset.url)
        XCTAssertEqual(context.artFilterToken, "Grainy Film")
    }
}
