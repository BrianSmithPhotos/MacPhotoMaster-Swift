import AppKit
import SwiftUI

/// Full-size preview + selected-images filmstrip. See docs/SPEC.md §1.
///
/// Takes the view model rather than a single `PhotoAsset` so the filmstrip below the preview can
/// read `variantMemberIDs`/`variantSelectedIDs` and resolve any member of the current selection —
/// not just the one asset shown large.
struct PreviewPanelView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel

    @State private var previewImage: CGImage?

    private var asset: PhotoAsset? { viewModel.selectedAsset }

    var body: some View {
        VStack(spacing: 8) {
            VStack {
                Spacer()
                if let previewImage {
                    GeometryReader { geo in
                        ZStack {
                            Image(decorative: previewImage, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                            if viewModel.subjectIsolationEnabled {
                                SubjectCropOverlay(
                                    imageSize: CGSize(
                                        width: previewImage.width, height: previewImage.height),
                                    containerSize: geo.size,
                                    committedRect: viewModel.manualSubjectCropRect,
                                    onCommit: viewModel.setManualCropRect
                                )
                            }
                        }
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
            .task(id: asset?.id) {
                previewImage = nil
                guard let asset else { return }
                previewImage = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 2048)
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
