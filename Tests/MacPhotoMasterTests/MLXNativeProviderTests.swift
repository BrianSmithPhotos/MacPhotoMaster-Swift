import CoreGraphics
import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Covers the two pieces of `MLXNativeProvider` that don't require loading a real MLX model:
/// base64→`CIImage` decoding and the `ensureVisionCapable` allowlist boundary. Everything above
/// this (prompting, JSON parsing, the timeout/empty-response retry chain) is already exercised by
/// `AISuggestionServiceTests`'s `FakeAIProvider` — see docs/MLX_PROVIDER.md for why real model
/// load/inference isn't unit tested here.
final class MLXNativeProviderTests: XCTestCase {
    private func makeJPEGBase64(width: Int = 8, height: Int = 8) -> String {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = ImageEncoding.jpegData(from: context.makeImage()!, compressionQuality: 0.85)!
        return data.base64EncodedString()
    }

    // MARK: - decodeImage

    func testDecodeImageValidBase64JPEGReturnsImage() {
        let base64 = makeJPEGBase64()

        XCTAssertNotNil(MLXNativeProvider.decodeImage(base64: base64))
    }

    func testDecodeImageGarbageBase64ReturnsNil() {
        XCTAssertNil(MLXNativeProvider.decodeImage(base64: "not valid base64!!"))
    }

    func testDecodeImageValidBase64ButNotImageDataReturnsNil() {
        let base64 = Data("hello world".utf8).base64EncodedString()

        XCTAssertNil(MLXNativeProvider.decodeImage(base64: base64))
    }

    // MARK: - ensureVisionCapable

    func testEnsureVisionCapableAllowlistedModelPasses() async throws {
        let provider = MLXNativeProvider()

        try await provider.ensureVisionCapable(model: "mlx-community/gemma-4-31b-it-8bit")
    }

    func testEnsureVisionCapableBlankModelThrows() async {
        let provider = MLXNativeProvider()

        do {
            try await provider.ensureVisionCapable(model: "   ")
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            XCTAssertEqual(error.errorDescription, "No MLX model selected")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testEnsureVisionCapableUnknownModelThrows() async {
        let provider = MLXNativeProvider()

        do {
            try await provider.ensureVisionCapable(model: "mlx-community/not-a-real-model")
            XCTFail("Expected a provider error")
        } catch let error as AISuggestionError {
            XCTAssertEqual(
                error.errorDescription,
                "\"mlx-community/not-a-real-model\" is not a recognized MLX vision model")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
