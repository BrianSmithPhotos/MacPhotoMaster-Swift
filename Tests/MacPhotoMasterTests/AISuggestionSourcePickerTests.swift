import XCTest

@testable import MacPhotoMaster

final class AISuggestionSourcePickerTests: XCTestCase {
    func testPrefersRAWOverJPEG() {
        let raw = PhotoAsset(id: URL(fileURLWithPath: "/card/P1010042.ORF"))
        let jpeg = PhotoAsset(id: URL(fileURLWithPath: "/card/P1010042.JPG"))

        let picked = AISuggestionSourcePicker.pickSourceAsset(from: [jpeg, raw])

        XCTAssertEqual(picked?.url, raw.url)
    }

    func testFallsBackToFirstJPEGByFilenameWhenNoRAWPresent() {
        let jpegB = PhotoAsset(id: URL(fileURLWithPath: "/card/B.jpg"))
        let jpegA = PhotoAsset(id: URL(fileURLWithPath: "/card/A.jpg"))

        let picked = AISuggestionSourcePicker.pickSourceAsset(from: [jpegB, jpegA])

        XCTAssertEqual(picked?.url, jpegA.url)
    }

    func testEmptyMembersReturnsNil() {
        XCTAssertNil(AISuggestionSourcePicker.pickSourceAsset(from: []))
    }
}
