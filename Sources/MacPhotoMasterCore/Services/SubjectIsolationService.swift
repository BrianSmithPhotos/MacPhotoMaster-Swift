import CoreGraphics
import CoreVideo
import Vision
import os

/// Crops to Vision's most salient foreground instance before triage/generation, so a small subject
/// (e.g. a bird occupying a fraction of the frame) isn't diluted by background scene labels/pixels —
/// see `AISuggestionService`'s doc comment for the motivating goldfinch triage-miss. Never a hard
/// requirement: any failure (no salient instance, request error, degenerate mask) returns `nil` and
/// the caller falls back to the original, uncropped image.
public enum SubjectIsolationService {
    private static let paddingFraction: CGFloat = 0.25
    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "SubjectIsolation")

    public static func isolateSubject(in image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.log(
                "Subject isolation request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            logger.log("Subject isolation found no salient instance")
            return nil
        }

        let maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try observation.generateMask(forInstances: observation.allInstances)
        } catch {
            logger.log(
                "Subject isolation mask generation failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        guard let maskBoundingBox = boundingBox(ofNonZeroPixelsIn: maskBuffer) else {
            logger.log("Subject isolation mask had no non-zero pixels")
            return nil
        }

        let scaleX = CGFloat(image.width) / CGFloat(CVPixelBufferGetWidth(maskBuffer))
        let scaleY = CGFloat(image.height) / CGFloat(CVPixelBufferGetHeight(maskBuffer))
        let imageSpaceBox = CGRect(
            x: maskBoundingBox.minX * scaleX, y: maskBoundingBox.minY * scaleY,
            width: maskBoundingBox.width * scaleX, height: maskBoundingBox.height * scaleY)

        let paddedBox = pad(imageSpaceBox, by: paddingFraction, clampingTo: image)
        guard let cropped = image.cropping(to: paddedBox) else {
            logger.log("Subject isolation crop failed")
            return nil
        }
        logger.log(
            "Subject isolation cropped to \(Int(paddedBox.width), privacy: .public)x\(Int(paddedBox.height), privacy: .public) from \(image.width, privacy: .public)x\(image.height, privacy: .public)"
        )
        return cropped
    }

    /// `generateMask(forInstances:)` returns a single-channel `kCVPixelFormatType_OneComponent32Float`
    /// buffer at the analysis resolution (not the input image's resolution) — instance-labeled, 0 for
    /// background, >0 for foreground — so the resulting box is in mask-space and must be scaled back
    /// up to image-space by the caller.
    public static func boundingBox(ofNonZeroPixelsIn pixelBuffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<width where row[x] > 0.5 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// `CGImage.cropping(to:)` treats `y: 0` as the first stored row (no vertical flip), matching the
    /// raw row-major layout scanned above — verified empirically, since Vision blog posts disagree on
    /// this and Apple's own docs don't spell it out.
    public static func pad(_ rect: CGRect, by fraction: CGFloat, clampingTo image: CGImage) -> CGRect {
        let paddedX = rect.width * fraction
        let paddedY = rect.height * fraction
        let padded = rect.insetBy(dx: -paddedX, dy: -paddedY)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        return padded.intersection(bounds)
    }
}
