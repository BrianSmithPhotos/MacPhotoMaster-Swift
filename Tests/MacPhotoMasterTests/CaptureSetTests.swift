import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

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

    /// A developed JPEG is still a JPEG, so without the derived check it would win the JPEG-first
    /// rule outright — and developing a set would move its identity off the file skip/processed
    /// state is recorded against.
    func testRepresentativeIgnoresARawDevelopedJPEGWhenTheCameraProvidedOne() {
        var derived = PhotoAsset(id: URL(fileURLWithPath: "/tmp/A_derived.jpg"))
        derived.derivedFrom = URL(fileURLWithPath: "/tmp/B.orf")
        let jpegB = PhotoAsset(id: URL(fileURLWithPath: "/tmp/B.jpg"))
        let set = CaptureSet(members: [derived, jpegB])

        XCTAssertEqual(set.representative?.id, jpegB.id)
    }

    /// The common OM-3 case: a RAW-only set. The ORF keeps representing it even though the derived
    /// JPEG would otherwise outrank it by extension.
    func testRepresentativeIgnoresARawDevelopedJPEGInFavourOfTheRawItCameFrom() {
        let raw = PhotoAsset(id: URL(fileURLWithPath: "/tmp/B.orf"))
        var derived = PhotoAsset(id: URL(fileURLWithPath: "/tmp/A_derived.jpg"))
        derived.derivedFrom = raw.id
        let set = CaptureSet(members: [raw, derived])

        XCTAssertEqual(set.representative?.id, raw.id)
    }

    func testRepresentativeFallsBackToADerivedAssetWhenItIsAllThereIs() {
        var derived = PhotoAsset(id: URL(fileURLWithPath: "/tmp/A_derived.jpg"))
        derived.derivedFrom = URL(fileURLWithPath: "/tmp/B.orf")
        let set = CaptureSet(members: [derived])

        XCTAssertEqual(set.representative?.id, derived.id)
    }

    func testRepresentativeIsNilForAnEmptySet() {
        let set = CaptureSet(members: [])

        XCTAssertNil(set.representative)
    }
}
