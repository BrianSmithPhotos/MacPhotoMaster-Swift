import CoreGraphics
import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class ImageEncodingTests: XCTestCase {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testJpegDataProducesNonEmptyData() {
        let image = makeImage(width: 40, height: 20)

        let data = ImageEncoding.jpegData(from: image, compressionQuality: 0.85)

        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }

    func testCenterCropHalvesDimensions() {
        let image = makeImage(width: 100, height: 50)

        let cropped = ImageEncoding.centerCrop(image, scale: 0.5)

        XCTAssertEqual(cropped?.width, 50)
        XCTAssertEqual(cropped?.height, 25)
    }

    func testCenterCropZeroScaleReturnsNil() {
        let image = makeImage(width: 100, height: 50)

        XCTAssertNil(ImageEncoding.centerCrop(image, scale: 0))
    }
}
