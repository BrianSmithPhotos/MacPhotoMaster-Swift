import SwiftUI
import UIKit

/// Pinch-zoomable large preview — the iPad counterpart to the Mac app's `ZoomableImageView`
/// (docs/SPEC.md §1 "Preview zoom").
///
/// `UIScrollView` already provides pinch, pan, momentum and the zoom-scale clamp, so unlike the Mac
/// version there's no gesture code here beyond double-tap; the only real work is keeping the image
/// centered when it's smaller than the pane, and recomputing what "Fit" means when the pane resizes
/// (rotation, Split View).
///
/// No crop-mode interlock here: the iPad app has no subject-isolation mode to conflict with.
struct ZoomableImageView: UIViewRepresentable {
    let image: CGImage
    /// Current scale as a multiple of Fit — 1.0 means the whole frame is visible. Two-way: the
    /// scroll view writes the user's zoom back out for the always-visible readout, and
    /// `PreviewPanelView` writes 1.0 in to reset to Fit.
    @Binding var fitMultiple: CGFloat

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView(image: image)
        scrollView.delegate = context.coordinator
        scrollView.onFitMultipleChange = { multiple in
            // Reported from inside UIKit's layout pass, which on the first run is also SwiftUI's
            // view update — writing the binding synchronously there trips "Modifying state during
            // view update". One hop to the next runloop turn is enough.
            DispatchQueue.main.async {
                guard abs(fitMultiple - multiple) > ZoomScrollView.scaleComparisonEpsilon else { return }
                fitMultiple = multiple
            }
        }
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        scrollView.applyFitMultiple(fitMultiple)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// `UIScrollView.delegate` is weak, so this has to be the coordinator (which SwiftUI retains)
    /// rather than the scroll view itself.
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.handleZoomChanged()
        }
    }
}

/// `UIScrollView` whose minimum zoom is "the whole image fits" rather than 1.0, so the preview can
/// never be zoomed out past the full frame. Scale is expressed to callers as a multiple of that
/// floor, matching the Mac app's `ZoomScrollView`.
final class ZoomScrollView: UIScrollView {
    private static let maximumFitMultiple: CGFloat = 8
    /// Where a double-tap zooms to, as a multiple of Fit — enough to be obviously a zoom without
    /// overshooting into the soft end of the 2048px decode.
    private static let doubleTapFitMultiple: CGFloat = 3
    /// Below this, two scales are the same as far as the readout and the reset-to-Fit check care.
    static let scaleComparisonEpsilon: CGFloat = 0.001

    let imageView: UIImageView
    var onFitMultipleChange: ((CGFloat) -> Void)?

    /// Keeps the preview pinned to Fit across pane resizes until the user actually zooms in — and
    /// through the first layout pass, where there's no pane size yet to compute Fit from.
    private var isPinnedToFit = true

    private var currentFitMultiple: CGFloat {
        minimumZoomScale > 0 ? zoomScale / minimumZoomScale : 1
    }

    init(image: CGImage) {
        // Sized in image pixels so the layer holds the image at its source resolution and zooming
        // interpolates from that rather than from a pane-sized bitmap — same reasoning as the Mac
        // app's document view.
        imageView = UIImageView(image: UIImage(cgImage: image))
        imageView.frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        super.init(frame: .zero)

        addSubview(imageView)
        contentSize = imageView.bounds.size
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = true
        backgroundColor = .clear
        // Centering below works in plain `bounds` terms; letting UIKit fold the safe area into the
        // inset as well would fight it.
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateZoomLimits()
        centerContent()
    }

    /// Recomputes Fit for the current pane size. Needed on rotation and Split View resizes, not just
    /// at setup — Fit is a function of the pane, and the floor has to move with it.
    private func updateZoomLimits() {
        let imageSize = imageView.bounds.size
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0
        else { return }
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        guard fit > 0, fit.isFinite else { return }
        minimumZoomScale = fit
        maximumZoomScale = fit * Self.maximumFitMultiple
        if isPinnedToFit {
            zoomScale = fit
        }
        onFitMultipleChange?(currentFitMultiple)
    }

    /// Keeps the image centered whenever it's smaller than the pane — at Fit, and on whichever axis
    /// has spare room when the aspect ratios differ. `UIScrollView` otherwise pins content to the
    /// top-left, which reads as the image jumping to the corner as you zoom back out.
    private func centerContent() {
        // `imageView.frame` already reflects `zoomScale`, unlike its `bounds`.
        let contentWidth = imageView.frame.width
        let contentHeight = imageView.frame.height
        let insetX = max(0, (bounds.width - contentWidth) / 2)
        let insetY = max(0, (bounds.height - contentHeight) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    func handleZoomChanged() {
        isPinnedToFit = currentFitMultiple <= 1 + Self.scaleComparisonEpsilon
        centerContent()
        onFitMultipleChange?(currentFitMultiple)
    }

    /// Applies a scale requested from SwiftUI (the readout's reset-to-Fit tap).
    func applyFitMultiple(_ multiple: CGFloat) {
        guard abs(multiple - currentFitMultiple) > Self.scaleComparisonEpsilon,
            minimumZoomScale > 0
        else { return }
        isPinnedToFit = multiple <= 1 + Self.scaleComparisonEpsilon
        setZoomScale(minimumZoomScale * multiple, animated: true)
    }

    /// Double-tap toggles between Fit and `doubleTapFitMultiple`, zooming at the tapped point — the
    /// conventional iOS photo-viewer gesture, and the only quick way in without a pinch.
    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard minimumZoomScale > 0 else { return }
        guard currentFitMultiple <= 1 + Self.scaleComparisonEpsilon else {
            isPinnedToFit = true
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let target = minimumZoomScale * Self.doubleTapFitMultiple
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        isPinnedToFit = false
        zoom(
            to: CGRect(
                x: point.x - size.width / 2, y: point.y - size.height / 2,
                width: size.width, height: size.height),
            animated: true)
    }
}
