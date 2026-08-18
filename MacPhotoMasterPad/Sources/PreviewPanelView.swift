import SwiftUI
import MacPhotoMasterCore

/// iPad counterpart to the macOS app's `PreviewPanelView` — big preview plus a filmstrip of the
/// selected capture set's members. The Mac version's cmd-click "ring-selection" (narrowing which
/// members a Save/Process action applies to beyond the grid's own multi-selection) has no touch
/// equivalent yet and isn't wired up here — there's nothing beyond `saveMetadata`'s/`process`'s
/// existing `.captureSet`/`.manualSelection` scopes for a ring-selection to further narrow until
/// that's designed. Tapping a filmstrip thumbnail just switches which member the big preview shows.
///
/// With "Crop to Subject" on (the metadata sheet's toggle), the zoomable preview is replaced by a
/// static Fit-scaled canvas carrying a `SubjectCropOverlay` — drag a box or tap a subject to set the
/// manual crop the next AI suggestion is sent, mirroring the Mac.
struct PreviewPanelView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel

    @State private var previewImage: CGImage?
    /// Preview scale as a multiple of Fit — see `ZoomableImageView.fitMultiple`. Pure view state
    /// (nothing outside this pane reads it), reset to Fit on every selection change by the `.task`.
    @State private var previewFitMultiple: CGFloat = 1

    private var asset: PhotoAsset? { viewModel.previewAsset }

    var body: some View {
        VStack(spacing: 8) {
            VStack {
                Spacer()
                if let previewImage {
                    if viewModel.subjectIsolationEnabled {
                        // Crop mode replaces the zoomable scroll view with a static, Fit-scaled canvas
                        // — pinch/pan off, same as the Mac (`PreviewPanelView.isZoomEnabled`) — because
                        // the overlay maps drags/taps to image pixels assuming an unzoomed `.fit`
                        // layout. Drag a box to crop, or tap a subject to pick it (`SubjectCropOverlay`).
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
                                    onCommitRect: { viewModel.setManualCropRect($0) },
                                    onTap: { viewModel.pickSubjectInstance(atImagePoint: $0) }
                                )
                            }
                            // GeometryReader places its child at .topLeading; keep the portrait
                            // (narrower-than-container) case centered, matching the Mac.
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                    } else {
                        ZoomableImageView(image: previewImage, fitMultiple: $previewFitMultiple)
                            // Rebuilds the scroll view (back at Fit, with the new image) when the
                            // selection changes, rather than mutating the existing one.
                            .id(asset?.id)
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)
                    Text(asset == nil ? "Select a photo" : "Loading…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                // Hidden in crop mode: zoom is off there, so the readout/reset control has nothing to
                // do (the metadata sheet's toggle hint spells out that zoom is suspended).
                if previewImage != nil, !viewModel.subjectIsolationEnabled {
                    ZoomReadout(fitMultiple: previewFitMultiple) { previewFitMultiple = 1 }
                        .padding(8)
                }
            }
            .task(id: asset?.id) {
                previewImage = nil
                previewFitMultiple = 1
                guard let asset else { return }
                previewImage = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 2048)
            }
            // Crop mode can't be entered at a zoom level its coordinate mapping doesn't account for —
            // reset to Fit whenever the toggle flips, mirroring the Mac.
            .onChange(of: viewModel.subjectIsolationEnabled) { _, _ in
                previewFitMultiple = 1
            }

            if let members = viewModel.selectedCaptureSet?.members, members.count > 1 {
                FilmstripView(
                    members: members,
                    activeAssetID: asset?.id,
                    skipActionTitle: viewModel.sourceViewFilter == .active ? "Skip" : "Un-skip",
                    onSelect: { viewModel.setActivePreview($0) },
                    onSkipAction: { member in
                        switch viewModel.sourceViewFilter {
                        case .active: viewModel.skipMember(member)
                        case .skipped: viewModel.unskipMember(member)
                        }
                    }
                )
            }
        }
    }
}

/// Always-visible preview scale readout — the iPad counterpart to the Mac app's (docs/SPEC.md §1).
/// Shown at Fit as well as when zoomed, because a zoomed preview and a differently-framed source
/// file are otherwise indistinguishable, and this app sends the AI a different file than it shows
/// (see `PhotoBrowserViewModel.aiEvaluatedImage`). Doubles as the reset-to-Fit control.
private struct ZoomReadout: View {
    let fitMultiple: CGFloat
    let onReset: () -> Void

    private var isAtFit: Bool { fitMultiple <= 1 + ZoomScrollView.scaleComparisonEpsilon }

    var body: some View {
        Button(action: onReset) {
            Text(isAtFit ? "Fit" : "\(Int((fitMultiple * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isAtFit)
        .accessibilityIdentifier("previewZoomReadout")
        .accessibilityLabel(isAtFit ? "Preview at fit" : "Preview zoomed, tap to fit")
    }
}

/// Row of every member of the selected capture set, shown under the large preview. Tapping a
/// thumbnail switches which member is previewed large; long-pressing one skips (or un-skips) that
/// single frame, leaving the rest of the set in place — see docs/SPEC.md §1.
private struct FilmstripView: View {
    let members: [PhotoAsset]
    let activeAssetID: PhotoAsset.ID?
    let skipActionTitle: String
    let onSelect: (PhotoAsset.ID) -> Void
    let onSkipAction: (PhotoAsset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 6) {
                ForEach(members) { member in
                    FilmstripTileView(
                        asset: member,
                        isActive: activeAssetID == member.id,
                        onSelect: { onSelect(member.id) }
                    )
                    .contextMenu {
                        Button(skipActionTitle) { onSkipAction(member) }
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: 92)
    }
}

/// One filmstrip thumbnail: accent-bordered when it's the actively previewed member.
private struct FilmstripTileView: View {
    let asset: PhotoAsset
    let isActive: Bool
    let onSelect: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: onSelect) {
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
                .clipped()
        }
        .buttonStyle(.plain)
        .task(id: asset.id) {
            thumbnail = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 160)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.url.lastPathComponent)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Drag-to-crop plus tap-to-pick overlay on the big preview, shown only while
/// `subjectIsolationEnabled` is on (see `PreviewPanelView`'s body). Draws a live rectangle while
/// dragging, or `committedRect` (the existing manual override) converted to view space when idle. A
/// single `DragGesture(minimumDistance: 0)` is the sole decision point: a drag past
/// `minimumCommitSize` commits a crop rect (`onCommitRect`); a touch that never grows past it is a
/// tap, which picks the Vision subject under the finger (`onTap`). Adapted from the Mac's
/// `SubjectCropOverlay`, which is drag-only — the tap branch is the iPad's touch alternative to the
/// Mac's plain-click-resets behaviour (reset lives on a button in the metadata sheet here instead).
private struct SubjectCropOverlay: View {
    let imageSize: CGSize
    let containerSize: CGSize
    let committedRect: CGRect?
    let onCommitRect: (CGRect?) -> Void
    let onTap: (CGPoint) -> Void

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
        // `minimumDistance: 0` so a plain tap still produces a gesture value — needed to tell "tap to
        // pick" from "drag to draw" ourselves below, rather than relying on SwiftUI's drag threshold
        // (which would silently swallow a tap).
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
                        onTap(
                            SubjectCropGeometry.imagePoint(
                                forViewPoint: end, imageSize: imageSize, containerSize: containerSize))
                        return
                    }
                    onCommitRect(
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
    PreviewPanelView(viewModel: PhotoBrowserViewModel())
}
