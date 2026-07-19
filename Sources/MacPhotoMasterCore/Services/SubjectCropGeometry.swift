import CoreGraphics

/// View-space <-> image-pixel-space mapping for an `.aspectRatio(.fit)`-scaled image inside an
/// arbitrary-size container, e.g. `PreviewPanelView`'s big preview. Kept free of SwiftUI so it's
/// unit-testable without instantiating a view hierarchy — see `SubjectCropGeometryTests`.
public enum SubjectCropGeometry {
    /// Where the image lands inside `containerSize` once SwiftUI's `.aspectRatio(.fit)` scales and
    /// centers it — the same letterboxing math SwiftUI applies internally.
    public static func fitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0,
            containerSize.height > 0
        else { return .zero }
        let scale = min(
            containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fitSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (containerSize.width - fitSize.width) / 2,
            y: (containerSize.height - fitSize.height) / 2)
        return CGRect(origin: origin, size: fitSize)
    }

    /// Maps a rectangle in container-local view space (e.g. a drag gesture's coordinates) to
    /// image-pixel space, clamped to the image's bounds — a drag that starts or ends in the
    /// letterbox margin never produces a rect outside the actual image.
    public static func imageRect(forViewRect viewRect: CGRect, imageSize: CGSize, containerSize: CGSize)
        -> CGRect
    {
        let fit = fitRect(imageSize: imageSize, containerSize: containerSize)
        guard fit.width > 0, fit.height > 0 else { return .zero }
        let invScale = imageSize.width / fit.width
        let raw = CGRect(
            x: (viewRect.minX - fit.minX) * invScale,
            y: (viewRect.minY - fit.minY) * invScale,
            width: viewRect.width * invScale,
            height: viewRect.height * invScale)
        return raw.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Inverse of `imageRect(forViewRect:imageSize:containerSize:)` — maps an image-pixel rect back
    /// to view space, for drawing an overlay outline over a committed crop rect.
    public static func viewRect(forImageRect imageRect: CGRect, imageSize: CGSize, containerSize: CGSize)
        -> CGRect
    {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let fit = fitRect(imageSize: imageSize, containerSize: containerSize)
        let scale = fit.width / imageSize.width
        return CGRect(
            x: fit.minX + imageRect.minX * scale,
            y: fit.minY + imageRect.minY * scale,
            width: imageRect.width * scale,
            height: imageRect.height * scale)
    }
}
