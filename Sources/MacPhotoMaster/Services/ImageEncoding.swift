import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `CGImage` encoding helpers for the AI-suggestion request path (docs/SPEC.md §6). `ImageIO`/
/// `CoreGraphics` only, no `AppKit` — keeps `Services/` free of UI-layer imports per
/// docs/ARCHITECTURE.md, even though this only ever runs off-main-thread work.
enum ImageEncoding {
    /// JPEG-encodes `image` via `CGImageDestination` (no `NSBitmapImageRep`, for the same
    /// no-`AppKit`-in-`Services` reason as above).
    static func jpegData(from image: CGImage, compressionQuality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Crops `image` to a centered region at `scale` of its original width/height — used by
    /// `AISuggestionService`'s timeout/empty-response fallback retry (docs/SPEC.md §6: "retry once
    /// with a cropped, lower-effort request"), matching the Python reference app's 50% center-crop
    /// fallback.
    static func centerCrop(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let croppedWidth = Int(CGFloat(image.width) * scale)
        let croppedHeight = Int(CGFloat(image.height) * scale)
        guard croppedWidth > 0, croppedHeight > 0 else { return nil }
        let origin = CGPoint(
            x: (image.width - croppedWidth) / 2, y: (image.height - croppedHeight) / 2)
        let rect = CGRect(origin: origin, size: CGSize(width: croppedWidth, height: croppedHeight))
        return image.cropping(to: rect)
    }
}
