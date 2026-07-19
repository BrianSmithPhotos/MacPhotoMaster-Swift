import CoreGraphics
import CoreVideo
import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class SubjectIsolationServiceTests: XCTestCase {
    /// A flat color swatch has no salient foreground instance for Vision to find — this is a wiring
    /// sanity check (the call fails closed to `nil`, never crashes/throws out), not a claim about
    /// Vision's segmentation accuracy on real photos, which isn't something a unit test should assert
    /// against.
    func testIsolateSubjectReturnsNilForNonPhotographicImage() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = context.makeImage()!

        XCTAssertNil(SubjectIsolationService.isolateSubject(in: image))
    }

    func testBoundingBoxOfNonZeroPixelsFindsExpectedRect() {
        let width = 10
        let height = 10
        var attributes: [String: Any] = [:]
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent32Float,
            attributes as CFDictionary, &pixelBufferOut)
        attributes = [:]
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = pixelBufferOut!

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                row[x] = (x >= 3 && x <= 5 && y >= 2 && y <= 4) ? 1.0 : 0.0
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let box = SubjectIsolationService.boundingBox(ofNonZeroPixelsIn: pixelBuffer)
        XCTAssertEqual(box, CGRect(x: 3, y: 2, width: 3, height: 3))
    }

    func testPadClampsToImageBounds() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!

        let padded = SubjectIsolationService.pad(
            CGRect(x: 0, y: 0, width: 4, height: 4), by: 1.0, clampingTo: image)

        XCTAssertEqual(padded, CGRect(x: 0, y: 0, width: 8, height: 8))
    }
}
