import XCTest

@testable import MacPhotoMaster

final class CaptureSetTests: XCTestCase {
    func testRepresentativePrefersFirstJPEGInFilenameOrder() {
        // Regression case for the reference app's lesson: picking "largest file" biases toward
        // heavily processed in-camera bracket renders. Filename-order-first JPEG is the proxy for
        // "the plain render" instead. See docs/SPEC.md §1.
        let raw = PhotoAsset(id: URL(fileURLWithPath: "/tmp/B.orf"))
        let jpegB = PhotoAsset(id: URL(fileURLWithPath: "/tmp/B.jpg"))
        let jpegA = PhotoAsset(id: URL(fileURLWithPath: "/tmp/A.jpeg"))
        let set = CaptureSet(members: [raw, jpegB, jpegA])

        XCTAssertEqual(set.representative?.id, jpegA.id)
    }

    func testRepresentativeFallsBackToFirstMemberInFilenameOrderWhenNoJPEGPresent() {
        let rawB = PhotoAsset(id: URL(fileURLWithPath: "/tmp/B.orf"))
        let rawA = PhotoAsset(id: URL(fileURLWithPath: "/tmp/A.orf"))
        let set = CaptureSet(members: [rawB, rawA])

        XCTAssertEqual(set.representative?.id, rawA.id)
    }

    func testRepresentativeIsNilForAnEmptySet() {
        let set = CaptureSet(members: [])

        XCTAssertNil(set.representative)
    }
}
