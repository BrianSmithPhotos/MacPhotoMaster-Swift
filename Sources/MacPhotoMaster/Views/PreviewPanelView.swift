import AppKit
import SwiftUI
import MacPhotoMasterCore

/// The camera-look strip, held against the photo's own top-right corner rather than the pane's, so
/// it stays on the picture when the side panels are resized instead of drifting out over the
/// letterbox margin.
///
/// Split out of `PreviewPanelView.body` because the two together were slow enough for the type
/// checker to give up on.
private struct LookStripOverlay: View {
    let asset: PhotoAsset
    let previewImage: CGImage
    /// Where the photo is, as reported by the scroll view that draws it. Nil in crop mode, which has
    /// no scroll view and no zoom, so a plain aspect-fit describes it exactly.
    ///
    /// Reported rather than recomputed here because the zoomed case cannot be derived from `geo`:
    /// the scroll view's legacy scrollers inset its content by their full width and autohide, so the
    /// photo's right edge is 0, 17 or 34pt inside this overlay's own right edge depending on zoom.
    let reportedImageFrame: CGRect?

    /// A device pixel of disagreement between the two edges reads as an 8% difference at a 6pt gap
    /// and half that here, so the snapping above does the correcting and this makes what's left of
    /// it harder to see.
    private let inset: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let viewport = CGRect(origin: .zero, size: geo.size)
            let visible = reportedImageFrame ?? SubjectCropGeometry.fitRect(
                imageSize: CGSize(width: previewImage.width, height: previewImage.height),
                containerSize: geo.size)

            CameraLookStripView(
                look: asset.cameraLook, isRawFile: PhotoAssetLoader.isRaw(asset.url)
            )
            // Positioned by insets off a full-size frame rather than by an image-sized one: the
            // trailing edge then lands at `visible.maxX - inset` arithmetically, instead of
            // depending on how alignment behaves when the image is narrower than the strip.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, viewport.maxX - visible.maxX + inset)
            .padding(.top, visible.minY + inset)
        }
    }
}

/// Full-size preview + selected-images filmstrip. See docs/SPEC.md §1.
///
/// Takes the view model rather than a single `PhotoAsset` so the filmstrip below the preview can
/// read `variantMemberIDs`/`variantSelectedIDs` and resolve any member of the current selection —
/// not just the one asset shown large.
struct PreviewPanelView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel

    @State private var previewImage: CGImage?
    /// Preview scale as a multiple of Fit — see `ZoomableImageView.fitMultiple`. Held here rather
    /// than in the view model because it's pure view state (no service or persistence touches it).
    @State private var previewFitMultiple: CGFloat = 1
    /// Visible centre as a fraction of the image. Deliberately survives a selection change along
    /// with the scale above: switching between a RAW and its developed JPEG while zoomed in is a
    /// comparison, and starting the next one at Fit (or at its top-left corner) throws away the
    /// framing that comparison depends on.
    @State private var previewCenter = CGPoint(x: 0.5, y: 0.5)
    /// Where `ZoomableImageView` says the photo actually landed. Empty until its first layout pass
    /// reports, and left behind in crop mode, so both of those read it as "no report yet".
    @State private var previewImageFrame: CGRect = .zero

    private var asset: PhotoAsset? { viewModel.selectedAsset }

    /// Zoom and crop mode are mutually exclusive (docs/SPEC.md §1): the crop overlay maps drags to
    /// image pixels assuming an unzoomed `.fit` layout, and it owns the drag gesture.
    private var isZoomEnabled: Bool { !viewModel.subjectIsolationEnabled }

    /// Crop mode has no scroll view to report a frame, and the last one reported is stale there, so
    /// the look strip falls back to a plain aspect-fit — which is exact at crop mode's fixed zoom.
    private var reportedImageFrame: CGRect? {
        guard isZoomEnabled, !previewImageFrame.isEmpty else { return nil }
        return previewImageFrame
    }

    var body: some View {
        VStack(spacing: 8) {
            // spacing 0 and minLength 0 deliberately, and both are needed: a Spacer reserves the
            // platform's default length on its own account, on top of the gaps the VStack puts
            // between its children. The two Spacers only exist to centre the placeholder, but any
            // length they hold shrinks the image's container and pushes it down, while the look
            // strip's overlay measures this VStack undiminished. The strip then anchored above the
            // photo's top edge, and — because the shortfall feeds through an aspect-fit — out past
            // its right edge whenever the image fitted on height.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if let previewImage {
                    if isZoomEnabled {
                        ZoomableImageView(
                            image: previewImage, fitMultiple: $previewFitMultiple,
                            center: $previewCenter, visibleImageFrame: $previewImageFrame
                        )
                        // Rebuilds the scroll view with the new image when the selection changes,
                        // rather than mutating the existing one; the zoom and centre above are
                        // handed back to the rebuilt view so the position carries over.
                        .id(asset?.id)
                    } else {
                        GeometryReader { geo in
                            ZStack {
                                Image(decorative: previewImage, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                SubjectCropOverlay(
                                    imageSize: CGSize(
                                        width: previewImage.width, height: previewImage.height),
                                    containerSize: geo.size,
                                    committedRect: viewModel.manualSubjectCropRect,
                                    onCommit: viewModel.setManualCropRect
                                )
                            }
                            // GeometryReader places its child at .topLeading, not centered, and the
                            // ZStack otherwise only sizes to its content — without this the portrait
                            // (narrower-than-container) case renders left-justified instead of centered.
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                } else {
                    // Keeps its own spacing, which the VStack above no longer provides.
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 64))
                            .foregroundStyle(.tertiary)
                        Text(asset == nil ? "Select a photo" : "Loading…")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if previewImage != nil {
                    ZoomReadout(fitMultiple: previewFitMultiple, isEnabled: isZoomEnabled) {
                        previewFitMultiple = 1
                    }
                    .padding(8)
                }
            }
            .overlay {
                if viewModel.lookVisualiserEnabled, let asset, let previewImage {
                    LookStripOverlay(
                        asset: asset, previewImage: previewImage,
                        reportedImageFrame: reportedImageFrame
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .task(id: asset?.id) {
                previewImage = nil
                guard let asset else { return }
                previewImage = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 2048)
            }
            // Crop mode can't be entered at a zoom level its coordinate mapping doesn't account for.
            .onChange(of: viewModel.subjectIsolationEnabled) { _, _ in
                previewFitMultiple = 1
            }

            if viewModel.variantMemberIDs.count > 1 {
                SelectedImagesStripView(viewModel: viewModel)
            }
        }
    }
}

/// Row of every member of the current selection (see `SourceBrowserViewModel.variantMemberIDs`),
/// shown under the large preview. Plain click switches which member is previewed large; cmd-click
/// toggles a member's ring-selection (`variantSelectedIDs`) — the batch these tiles resolve to is
/// intended to back AI/process-move actions that operate on a fine-tuned subset, mirroring the
/// reference app's variant strip.
private struct SelectedImagesStripView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel

    private var members: [PhotoAsset] {
        // Both lists, not just the currently-displayed filter — the active preview can be a
        // skipped capture set (see `SourceBrowserViewModel.selectedAsset`), so a multi-file skipped
        // set (e.g. a RAW+JPEG pair) still needs its members resolvable here.
        let allMembers = (viewModel.captureSets + viewModel.skippedCaptureSets).flatMap(\.members)
        let assetByID = Dictionary(uniqueKeysWithValues: allMembers.map { ($0.id, $0) })
        return viewModel.variantMemberIDs.compactMap { assetByID[$0] }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 6) {
                ForEach(members) { member in
                    VariantTileView(
                        asset: member,
                        isRingSelected: viewModel.variantSelectedIDs.contains(member.id),
                        isActive: viewModel.selectedAssetID == member.id,
                        isProcessed: viewModel.isProcessed(member),
                        onPlainSelect: { viewModel.setActivePreview(member.id) },
                        onToggleSelect: { viewModel.toggleVariantSelection(member.id) }
                    )
                    // Per-file counterparts to the capture-set actions in `SourcePanelView`: act on
                    // just this one frame rather than every member of its set. Skip/Un-skip follow
                    // the same rule as the grid's — which one is offered depends on which filter is
                    // being browsed, so a tile can't be skipped twice or un-skipped while active.
                    .contextMenu {
                        switch viewModel.sourceViewFilter {
                        case .active:
                            Button("Skip") { viewModel.skipMember(member) }
                        case .skipped:
                            Button("Un-skip") { viewModel.unskipMember(member) }
                        }
                        Button("Develop RAW") {
                            viewModel.developRAW(scope: .singleAsset(member))
                        }
                        .disabled(
                            viewModel.isDevelopingRAW
                                || !viewModel.canDevelopRAW(scope: .singleAsset(member)))
                    }
                }
            }
            .padding(.top, 4)
            // Top-aligned in a taller-than-content frame (rather than the default vertical
            // centering) so the tiles sit near the top of the strip, leaving clear room below for
            // the horizontal scroll bar instead of it overlapping the tiles' bottom edge — see
            // GitHub issue #5.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: 92)
    }
}

/// One filmstrip thumbnail: dimmed when ring-deselected, accent-bordered when it's the actively
/// previewed member.
private struct VariantTileView: View {
    let asset: PhotoAsset
    let isRingSelected: Bool
    let isActive: Bool
    /// Non-blocking hint that this file has already been through Process & Move at least once —
    /// see `ProcessedStateStore`'s doc comment. Never disables re-selecting or reprocessing it.
    let isProcessed: Bool
    let onPlainSelect: () -> Void
    let onToggleSelect: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) {
                onToggleSelect()
            } else {
                onPlainSelect()
            }
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 82, height: 60)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(asset.url.pathExtension.uppercased())
                            .font(.caption2)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isProcessed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .padding(2)
                            .background(.green, in: Circle())
                            .foregroundStyle(.white)
                            .padding(3)
                    }
                }
                .opacity(isRingSelected ? 1.0 : 0.4)
                .clipped()
        }
        .buttonStyle(.plain)
        .task(id: asset.id) {
            thumbnail = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 160)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("variantTile.\(asset.id.lastPathComponent)")
        .accessibilityLabel(asset.url.lastPathComponent)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Always-visible preview scale readout (docs/SPEC.md §1): shown at Fit as well as when zoomed,
/// because a zoomed preview and a differently-framed source file are otherwise indistinguishable —
/// the confusion that motivated the feature. Doubles as the reset control (click, or ⌘0).
private struct ZoomReadout: View {
    let fitMultiple: CGFloat
    let isEnabled: Bool
    let onReset: () -> Void

    private var isAtFit: Bool { fitMultiple <= 1 + ZoomScrollView.scaleComparisonEpsilon }

    private var label: String {
        isAtFit ? "Fit" : "\(Int((fitMultiple * 100).rounded()))%"
    }

    var body: some View {
        Button(action: onReset) {
            Text(isEnabled ? label : "Fit (crop mode)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isAtFit)
        .keyboardShortcut("0", modifiers: .command)
        .help(isEnabled ? "Scroll to zoom. Click to fit (Cmd-0)." : "Zoom is off while crop mode is on")
        .accessibilityIdentifier("previewZoomReadout")
    }
}

/// Click-drag-to-crop overlay on the big preview, shown only while `subjectIsolationEnabled` is on
/// (see `PreviewPanelView`'s body). Draws a live rectangle while dragging, or `committedRect` (the
/// existing manual override, if any) converted to view space when idle. A drag that never exceeds
/// `minimumCommitSize` in view space — a plain click — commits `nil` instead, resetting back to the
/// AI-computed crop; see `SourceBrowserViewModel.setManualCropRect`.
private struct SubjectCropOverlay: View {
    let imageSize: CGSize
    let containerSize: CGSize
    let committedRect: CGRect?
    let onCommit: (CGRect?) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    private static let minimumCommitSize: CGFloat = 8

    private var fit: CGRect {
        SubjectCropGeometry.fitRect(imageSize: imageSize, containerSize: containerSize)
    }

    var body: some View {
        ZStack {
            if let dragStart, let dragCurrent {
                outline(for: normalizedRect(dragStart, dragCurrent))
            } else if let committedRect {
                outline(
                    for: SubjectCropGeometry.viewRect(
                        forImageRect: committedRect, imageSize: imageSize, containerSize: containerSize))
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .contentShape(Rectangle())
        // `minimumDistance: 0` so a plain click (no movement) still produces a gesture value —
        // needed to distinguish "click to reset" from "drag to draw" ourselves below, rather than
        // relying on SwiftUI's drag-recognition threshold (which would silently swallow a click).
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if dragStart == nil { dragStart = clamp(value.startLocation) }
                    dragCurrent = clamp(value.location)
                }
                .onEnded { value in
                    let start = clamp(value.startLocation)
                    let end = clamp(value.location)
                    dragStart = nil
                    dragCurrent = nil
                    let viewRect = normalizedRect(start, end)
                    guard viewRect.width >= Self.minimumCommitSize
                        || viewRect.height >= Self.minimumCommitSize
                    else {
                        onCommit(nil)
                        return
                    }
                    onCommit(
                        SubjectCropGeometry.imageRect(
                            forViewRect: viewRect, imageSize: imageSize, containerSize: containerSize))
                }
        )
    }

    private func outline(for rect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.12))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, fit.minX), fit.maxX), y: min(max(point.y, fit.minY), fit.maxY))
    }
}

#Preview {
    PreviewPanelView(viewModel: SourceBrowserViewModel())
}
