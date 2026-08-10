import AppKit
import SwiftUI

/// Pointer-anchored zoomable large preview — docs/SPEC.md §1 "Preview zoom".
///
/// Wraps `NSScrollView` rather than SwiftUI's `ScrollView` for three things AppKit already does
/// correctly and SwiftUI would need reimplementing: `setMagnification(_:centeredAt:)` (keeps the
/// image point under the cursor fixed), automatic scrollers once the scaled image overflows the
/// pane, and trackpad pinch. Only the scroll-wheel-to-magnification routing and drag-to-pan are
/// ours.
///
/// Shown only while subject-isolation crop mode is off; `PreviewPanelView` swaps in the plain
/// `Image` + `SubjectCropOverlay` otherwise, so the drag gesture only ever has one owner.
struct ZoomableImageView: NSViewRepresentable {
    let image: CGImage
    /// Current scale as a multiple of Fit — 1.0 means the whole frame is visible. Two-way: the
    /// scroll view writes the user's zoom back out for `PreviewPanelView`'s always-visible readout,
    /// and `PreviewPanelView` writes 1.0 in to reset to Fit (the readout button, ⌘0).
    @Binding var fitMultiple: CGFloat
    /// Visible centre as a fraction of the image (0...1 on each axis), read back out as the user
    /// zooms and pans. `PreviewPanelView` holds it across selection changes and hands it back here,
    /// which is what keeps the same part of the frame in view when switching between variants —
    /// normalized rather than in pixels because the two previews needn't be the same size.
    @Binding var center: CGPoint
    /// Where the image actually sits on screen, in this view's own coordinates — read out for the
    /// camera-look strip, which anchors to the photo's corner rather than the pane's.
    @Binding var visibleImageFrame: CGRect

    func makeNSView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        // Must be assigned before `documentView`: `NSScrollView` re-parents the document view into
        // whatever clip view it currently has.
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.documentView = PreviewDocumentView(image: image)
        scrollView.onFitMultipleChange = { multiple in
            // AppKit reports this from inside its own layout pass, which is also SwiftUI's view
            // update on the first run — writing the binding synchronously there trips "Modifying
            // state during view update". One hop to the next runloop turn is enough.
            DispatchQueue.main.async {
                guard abs(fitMultiple - multiple) > ZoomScrollView.scaleComparisonEpsilon else { return }
                fitMultiple = multiple
            }
        }
        scrollView.onCenterChange = { point in
            // Same one-runloop-turn hop, and for the same reason, as the scale binding above.
            DispatchQueue.main.async {
                guard abs(center.x - point.x) > ZoomScrollView.scaleComparisonEpsilon
                    || abs(center.y - point.y) > ZoomScrollView.scaleComparisonEpsilon
                else { return }
                center = point
            }
        }
        scrollView.onVisibleImageFrameChange = { frame in
            // Same one-runloop-turn hop, and for the same reason, as the two bindings above.
            DispatchQueue.main.async {
                guard visibleImageFrame != frame else { return }
                visibleImageFrame = frame
            }
        }
        scrollView.onResetRequested = {
            DispatchQueue.main.async { fitMultiple = 1 }
        }
        // Deferred rather than applied here: Fit can't be computed until there's a laid-out pane to
        // measure against, so the scroll view applies this on its first real layout pass.
        scrollView.restoreOnFirstLayout(fitMultiple: fitMultiple, center: center)
        return scrollView
    }

    func updateNSView(_ scrollView: ZoomScrollView, context: Context) {
        scrollView.applyFitMultiple(fitMultiple)
    }
}

/// `NSScrollView` whose magnification floor is "the whole image fits" rather than 1.0, so the
/// preview can never be zoomed out past the full frame (docs/SPEC.md §1). Scale is expressed to
/// callers as a multiple of that floor.
final class ZoomScrollView: NSScrollView {
    /// Multiplicative zoom per unit of wheel delta. Exponential rather than additive so a detented
    /// mouse wheel and a trackpad's fine-grained deltas both feel linear at any current zoom.
    private static let zoomPerWheelUnit: CGFloat = 1.06
    /// Precise (trackpad) deltas arrive roughly an order of magnitude larger than wheel detents for
    /// the same intended gesture; without this a two-finger swipe would slam straight to the cap.
    private static let preciseDeltaDamping: CGFloat = 10
    private static let maximumFitMultiple: CGFloat = 8
    /// Below this, two scales are the same as far as the readout and the reset-to-Fit check care.
    static let scaleComparisonEpsilon: CGFloat = 0.001

    var onFitMultipleChange: ((CGFloat) -> Void)?
    var onCenterChange: ((CGPoint) -> Void)?
    var onVisibleImageFrameChange: ((CGRect) -> Void)?
    var onResetRequested: (() -> Void)?

    /// Keeps the preview pinned to Fit across pane resizes until the user actually zooms in — and
    /// through the first layout pass, where there's no pane size yet to compute Fit from.
    private var isPinnedToFit = true

    /// Scale and normalized centre to adopt on the first layout pass that has a pane size, then
    /// cleared. This is how a zoom survives a selection change: switching photos tears this view
    /// down and builds a new one, so the state has to be re-applied from the outside rather than
    /// held here.
    private var pendingRestore: (fitMultiple: CGFloat, center: CGPoint)?

    func restoreOnFirstLayout(fitMultiple: CGFloat, center: CGPoint) {
        guard fitMultiple > 1 + Self.scaleComparisonEpsilon else { return }
        pendingRestore = (fitMultiple, center)
        isPinnedToFit = false
    }

    /// Magnification at which the whole image is visible. Depends on the pane size, so it's
    /// recomputed on every layout rather than cached.
    private var fitMagnification: CGFloat {
        guard let documentView else { return 1 }
        let imageSize = documentView.frame.size
        let available = contentView.frame.size
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0
        else { return 1 }
        return min(available.width / imageSize.width, available.height / imageSize.height)
    }

    private var currentFitMultiple: CGFloat {
        let fit = fitMagnification
        return fit > 0 ? magnification / fit : 1
    }

    override func layout() {
        super.layout()
        let fit = fitMagnification
        guard fit > 0 else { return }
        minMagnification = fit
        maxMagnification = fit * Self.maximumFitMultiple
        if let restore = pendingRestore {
            pendingRestore = nil
            magnification = fit * restore.fitMultiple
            scroll(toNormalizedCenter: restore.center)
        } else if isPinnedToFit {
            magnification = fit
        }
        onFitMultipleChange?(currentFitMultiple)
        onCenterChange?(normalizedCenter)
        onVisibleImageFrameChange?(visibleImageFrame)
    }

    /// The on-screen rectangle the image occupies, in this view's own coordinates — which are
    /// top-left, because `NSScrollView` is a flipped view, so the result drops straight into SwiftUI
    /// without a flip.
    ///
    /// Deliberately published rather than recomputed by the caller from the pane's size: legacy
    /// scrollers inset `contentView` by their full width (17pt each on this OS) and they autohide,
    /// so the content area is 0, 17 or 34pt smaller than the pane depending on the current zoom.
    /// Nothing outside this view can know which of those applies.
    ///
    /// `CenteringClipView` centres the image on whichever axis has spare room and pins it to the
    /// content area on whichever doesn't, so intersecting the centred scaled rect with that area is
    /// exact in both cases and needs no scroll offset.
    ///
    /// Snapped to the backing store because the centring above is arithmetic while the image is
    /// *drawn* on the pixel grid: a half-point of disagreement between the two is a whole device
    /// pixel, and whether it rounds towards or away from the caller's anchor depends on the pane's
    /// width — which is what made the look strip's gap look right at one size and a pixel tight at
    /// the next.
    private var visibleImageFrame: CGRect {
        guard let documentView else { return bounds }
        let area = contentView.frame
        let scaled = CGSize(
            width: documentView.frame.width * magnification,
            height: documentView.frame.height * magnification)
        let centred = CGRect(
            x: area.midX - scaled.width / 2, y: area.midY - scaled.height / 2,
            width: scaled.width, height: scaled.height)
        let visible = centred.intersection(area)
        return backingAlignedRect(visible.isNull ? area : visible, options: .alignAllEdgesNearest)
    }

    /// Visible centre as a fraction of the image on each axis. `contentView.bounds` is in document
    /// space (already divided by magnification), so it's directly comparable to the document view's
    /// unscaled frame — the same relationship `CenteringClipView` relies on.
    private var normalizedCenter: CGPoint {
        guard let documentView else { return CGPoint(x: 0.5, y: 0.5) }
        let size = documentView.frame.size
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: contentView.bounds.midX / size.width, y: contentView.bounds.midY / size.height)
    }

    /// The visible size is derived from the clip view's *frame* and the magnification just set,
    /// rather than read from its bounds: this runs mid-layout, where the bounds haven't caught up
    /// with a magnification assigned moments earlier.
    private func scroll(toNormalizedCenter center: CGPoint) {
        guard let documentView, magnification > 0 else { return }
        let imageSize = documentView.frame.size
        let visible = CGSize(
            width: contentView.frame.width / magnification,
            height: contentView.frame.height / magnification)
        let origin = NSPoint(
            x: center.x * imageSize.width - visible.width / 2,
            y: center.y * imageSize.height - visible.height / 2)
        let constrained = contentView.constrainBoundsRect(NSRect(origin: origin, size: visible))
        contentView.setBoundsOrigin(constrained.origin)
        reflectScrolledClipView(contentView)
    }

    /// Called after a pan or zoom so the view's owner can carry the position to the next photo.
    func reportCenter() {
        onCenterChange?(normalizedCenter)
    }

    /// Applies a scale requested from SwiftUI (the reset-to-Fit paths). Centered on the pane rather
    /// than the pointer — there's no pointer involved in a keyboard or button reset.
    func applyFitMultiple(_ multiple: CGFloat) {
        guard abs(multiple - currentFitMultiple) > Self.scaleComparisonEpsilon else { return }
        let fit = fitMagnification
        guard fit > 0 else { return }
        isPinnedToFit = multiple <= 1 + Self.scaleComparisonEpsilon
        setMagnification(fit * multiple, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
        onFitMultipleChange?(currentFitMultiple)
        reportCenter()
        onVisibleImageFrameChange?(visibleImageFrame)
    }

    /// Wheel zooms instead of scrolling — the whole point of the feature (docs/SPEC.md §1); panning
    /// is on the scrollers and drag instead. Crop mode never reaches here, so nothing else wants the
    /// wheel while this view exists.
    override func scrollWheel(with event: NSEvent) {
        let rawDelta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / Self.preciseDeltaDamping
            : event.scrollingDeltaY
        guard rawDelta != 0 else { return }
        let fit = fitMagnification
        guard fit > 0 else { return }

        let target = (currentFitMultiple * pow(Self.zoomPerWheelUnit, rawDelta))
            .clamped(to: 1...Self.maximumFitMultiple)
        isPinnedToFit = target <= 1 + Self.scaleComparisonEpsilon
        // `contentView` (the clip view) expresses its own coordinates in document space including
        // the current scroll offset and magnification, so this converts straight to the image point
        // under the cursor — which is what `centeredAt:` needs to hold still.
        setMagnification(fit * target, centeredAt: contentView.convert(event.locationInWindow, from: nil))
        onFitMultipleChange?(currentFitMultiple)
        reportCenter()
        onVisibleImageFrameChange?(visibleImageFrame)
    }

    func requestReset() {
        onResetRequested?()
    }
}

/// Keeps the image centered in the pane whenever it's smaller than the visible area — at Fit, and on
/// whichever axis has spare room when the aspect ratios differ. `NSScrollView`'s stock behaviour is
/// to pin the document to the bounds origin instead, which reads as the image jumping to the left
/// (and top) edge as you zoom back out.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        // `bounds` is in document space, so under magnification it's already the *scaled* visible
        // area — directly comparable to the document view's unscaled frame.
        let documentSize = documentView.frame.size
        if bounds.width > documentSize.width {
            bounds.origin.x = (documentSize.width - bounds.width) / 2
        }
        if bounds.height > documentSize.height {
            bounds.origin.y = (documentSize.height - bounds.height) / 2
        }
        return bounds
    }
}

/// Document view for `ZoomScrollView`. Sized in *image pixels* rather than fitted to the pane: that
/// makes the layer rasterize at the source image's own resolution, so magnifying interpolates from
/// full resolution instead of from a pane-sized bitmap (the difference between a soft zoom and a
/// sharp one). Beyond the 2048px decode cap it necessarily goes soft — that limit is the decode's,
/// not this view's.
final class PreviewDocumentView: NSView {
    private let image: CGImage
    /// Point in clip-view (document) space where the current pan drag started. Deliberately not
    /// updated mid-drag: holding the original point fixed is what makes the image track the cursor.
    private var panAnchor: NSPoint?

    init(image: CGImage) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Top-left origin, so a zoomed image starts at the top of the frame rather than the bottom.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        // `isFlipped` gives the view a y-down CTM, but `CGContext.draw` places images bottom-up —
        // undo the flip for the image draw alone rather than for the whole coordinate system.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        guard let clipView = enclosingScrollView?.contentView else { return }
        if event.clickCount == 2 {
            (enclosingScrollView as? ZoomScrollView)?.requestReset()
            panAnchor = nil
            return
        }
        panAnchor = clipView.convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panAnchor, let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let current = clipView.convert(event.locationInWindow, from: nil)
        // Both points are in document space, so the delta needs no magnification scaling. Dragging
        // the image right must move the viewport left, hence the subtraction.
        var origin = clipView.bounds.origin
        origin.x -= current.x - panAnchor.x
        origin.y -= current.y - panAnchor.y
        let constrained = clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size))
        clipView.setBoundsOrigin(constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// The pan's new position is published once here rather than on every dragged event: nothing
    /// reads it until the selection changes, and a per-frame SwiftUI state write would re-render the
    /// whole preview pane throughout the drag.
    override func mouseUp(with event: NSEvent) {
        panAnchor = nil
        (enclosingScrollView as? ZoomScrollView)?.reportCenter()
    }
}

extension CGFloat {
    fileprivate func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
