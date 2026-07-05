import CoreGraphics
import XCTest

@testable import MacPhotoMaster

final class SceneTriageServiceTests: XCTestCase {
    /// A flat color swatch isn't a bird or a flower under any real classifier — this is a wiring
    /// sanity check (the call succeeds and defaults sensibly), not a claim about Vision's accuracy
    /// on real photos, which isn't something a unit test should assert against.
    func testClassifyReturnsOtherForNonPhotographicImage() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = context.makeImage()!

        XCTAssertEqual(SceneTriageService.classify(image), .other)
    }
}
