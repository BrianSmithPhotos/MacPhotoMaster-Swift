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

    /// Padded image-pixel bounding box of the single foreground instance whose mask covers
    /// `imagePoint` — the tap-to-pick counterpart to `isolateSubject`'s "most salient instance"
    /// auto-crop, used on iPad so a tap chooses *which* subject when Vision finds several (a pair of
    /// birds, a subject beside a distractor). `imagePoint` is in image-pixel space (y down, first
    /// stored row = 0), the same space as the returned rect and as `CGImage.cropping(to:)`. Returns
    /// `nil` when the request fails, finds no instances, or the tap lands on background — the caller
    /// then leaves the current crop unchanged. When instances overlap at the point, the one with the
    /// smallest bounding box wins, since the tighter instance is the more specific pick.
    public static func subjectInstanceRect(in image: CGImage, at imagePoint: CGPoint) -> CGRect? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.log(
                "Instance pick request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            return nil
        }

        var bestBox: CGRect?
        for instance in observation.allInstances {
            guard let mask = try? observation.generateMask(forInstances: [instance]) else { continue }
            let maskWidth = CVPixelBufferGetWidth(mask)
            let maskHeight = CVPixelBufferGetHeight(mask)
            guard maskWidth > 0, maskHeight > 0 else { continue }
            let maskX = Int(imagePoint.x / CGFloat(image.width) * CGFloat(maskWidth))
            let maskY = Int(imagePoint.y / CGFloat(image.height) * CGFloat(maskHeight))
            guard maskValue(in: mask, atX: maskX, y: maskY) > 0.5,
                let box = boundingBox(ofNonZeroPixelsIn: mask)
            else { continue }
            let scaleX = CGFloat(image.width) / CGFloat(maskWidth)
            let scaleY = CGFloat(image.height) / CGFloat(maskHeight)
            let imageBox = CGRect(
                x: box.minX * scaleX, y: box.minY * scaleY,
                width: box.width * scaleX, height: box.height * scaleY)
            if bestBox == nil || imageBox.width * imageBox.height < bestBox!.width * bestBox!.height {
                bestBox = imageBox
            }
        }
        guard let chosen = bestBox else { return nil }
        return pad(chosen, by: paddingFraction, clampingTo: image)
    }

    /// Single-pixel read of a `kCVPixelFormatType_OneComponent32Float` mask, bounds-checked — returns
    /// 0 for an out-of-range coordinate so a tap in the letterbox margin reads as background.
    private static func maskValue(in pixelBuffer: CVPixelBuffer, atX x: Int, y: Int) -> Float32 {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
        return row[x]
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
