import CoreGraphics
import XCTest

@testable import MacPhotoMaster

final class SubjectCropGeometryTests: XCTestCase {
    private let imageSize = CGSize(width: 2000, height: 1000)

    func testFitRectLetterboxesOnHeightWhenContainerIsTaller() {
        // Container is a square; a 2:1 image fits full-width with vertical letterboxing.
        let container = CGSize(width: 1000, height: 1000)
        let fit = SubjectCropGeometry.fitRect(imageSize: imageSize, containerSize: container)
        XCTAssertEqual(fit, CGRect(x: 0, y: 250, width: 1000, height: 500))
    }

    func testFitRectLetterboxesOnWidthWhenContainerIsWider() {
        // Container is wider than the image's 2:1 aspect ratio, so the image fits full-height with
        // horizontal letterboxing.
        let container = CGSize(width: 3000, height: 1000)
        let fit = SubjectCropGeometry.fitRect(imageSize: imageSize, containerSize: container)
        XCTAssertEqual(fit, CGRect(x: 500, y: 0, width: 2000, height: 1000))
    }

    func testFitRectFullBleedWhenAspectRatiosMatch() {
        let container = CGSize(width: 400, height: 200)
        let fit = SubjectCropGeometry.fitRect(imageSize: imageSize, containerSize: container)
        XCTAssertEqual(fit, CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    func testFitRectDegenerateInputsReturnZero() {
        XCTAssertEqual(
            SubjectCropGeometry.fitRect(imageSize: .zero, containerSize: CGSize(width: 10, height: 10)),
            .zero)
        XCTAssertEqual(
            SubjectCropGeometry.fitRect(imageSize: imageSize, containerSize: .zero), .zero)
    }

    func testImageRectMapsCenterOfContainerToCenterOfImage() {
        let container = CGSize(width: 1000, height: 1000)  // fit rect: (0, 250, 1000, 500)
        let viewRect = CGRect(x: 400, y: 450, width: 200, height: 100)  // centered box in the fit rect
        let result = SubjectCropGeometry.imageRect(
            forViewRect: viewRect, imageSize: imageSize, containerSize: container)
        XCTAssertEqual(result, CGRect(x: 800, y: 400, width: 400, height: 200))
    }

    func testImageRectClampsDragThatExtendsIntoLetterboxMargin() {
        let container = CGSize(width: 1000, height: 1000)  // fit rect: (0, 250, 1000, 500)
        // Drag from inside the letterbox margin (y: 0) down into the image.
        let viewRect = CGRect(x: -50, y: 0, width: 200, height: 400)
        let result = SubjectCropGeometry.imageRect(
            forViewRect: viewRect, imageSize: imageSize, containerSize: container)
        XCTAssertTrue(CGRect(origin: .zero, size: imageSize).contains(result))
        XCTAssertEqual(result.minX, 0, accuracy: 0.001)
        XCTAssertEqual(result.minY, 0, accuracy: 0.001)
    }

    func testViewRectAndImageRectRoundTripForARectFullyInsideBounds() {
        let container = CGSize(width: 1200, height: 900)
        let original = CGRect(x: 300, y: 100, width: 800, height: 400)
        let view = SubjectCropGeometry.viewRect(
            forImageRect: original, imageSize: imageSize, containerSize: container)
        let roundTripped = SubjectCropGeometry.imageRect(
            forViewRect: view, imageSize: imageSize, containerSize: container)
        XCTAssertEqual(roundTripped.minX, original.minX, accuracy: 0.01)
        XCTAssertEqual(roundTripped.minY, original.minY, accuracy: 0.01)
        XCTAssertEqual(roundTripped.width, original.width, accuracy: 0.01)
        XCTAssertEqual(roundTripped.height, original.height, accuracy: 0.01)
    }
}
