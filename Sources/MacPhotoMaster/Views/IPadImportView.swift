import SwiftUI
import UniformTypeIdentifiers
import MacPhotoMasterCore

/// Sheet driving `SourceBrowserViewModel.importIPadExport(from:)` — pick a folder pulled off the
/// iPad, watch it import, read what was skipped.
///
/// A sheet rather than a row in `SettingsView` (where the library folder and the Timeline refresh
/// live) because this isn't a preference: it's a batch action whose per-file failure list is the
/// point. A skipped file keeps the description, keywords and GPS entered on the iPad and nothing
/// else knows they exist, so it has to be visible rather than folded into a one-line status.
struct IPadImportView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var exportRoot: URL?
    @State private var isChoosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from iPad")
                .font(.headline)

            Text(
                "Finishes files the iPad processed but could not complete: reads the in-camera effect from the maker notes, folds each XMP sidecar into its image, develops a JPEG from every RAW marked for develop on the iPad, and moves everything into the library."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Form {
                LabeledContent("Pulled Folder") {
                    HStack {
                        Text(exportRoot?.path ?? "Not chosen")
                            .foregroundStyle(exportRoot == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { isChoosingFolder = true }
                            .disabled(viewModel.isImportingIPadExport)
                    }
                }
                LabeledContent("Library Folder") {
                    Text(viewModel.libraryRootURL?.path ?? "Not set — choose one in Settings")
                        .foregroundStyle(viewModel.libraryRootURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .formStyle(.grouped)

            if let message = viewModel.iPadImportStatusMessage {
                VStack(alignment: .leading, spacing: 8) {
                    // The bar only appears once a total is known; until then the scan and the
                    // batched maker-note read have no countable unit, so the spinner stands in.
                    if viewModel.isImportingIPadExport, viewModel.iPadImportTotalCount > 0 {
                        ProgressView(
                            value: Double(viewModel.iPadImportedFileCount),
                            total: Double(viewModel.iPadImportTotalCount))
                    }
                    HStack(spacing: 8) {
                        if viewModel.isImportingIPadExport, viewModel.iPadImportTotalCount == 0 {
                            ProgressView().controlSize(.small)
                        }
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let summary = viewModel.iPadImportSummary {
                if !summary.failures.isEmpty {
                    FileReasonList(
                        title: "Skipped \(summary.failures.count) file(s)",
                        entries: summary.failures.map {
                            ($0.sourceName, $0.reason ?? "Unknown reason")
                        })
                }
                // Its own list rather than folded into the one above: these files *did* import,
                // only their RAW develop failed, so they are not waiting in the pulled folder to
                // be retried the way a skipped file is.
                if !summary.developFailures.isEmpty {
                    FileReasonList(
                        title: "RAW develop failed on \(summary.developFailures.count) file(s)",
                        entries: summary.developFailures.map {
                            ($0.sourceName, $0.developFailureReason ?? "Unknown reason")
                        })
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Close") { dismiss() }
                    .disabled(viewModel.isImportingIPadExport)
                Spacer()
                Button("Import") {
                    guard let exportRoot else { return }
                    viewModel.importIPadExport(from: exportRoot)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    exportRoot == nil || viewModel.libraryRootURL == nil || viewModel.isImportingIPadExport)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                exportRoot = url
            }
        }
    }
}

/// Per-file failures with the reason each one carries. Used for the files that stayed behind — that
/// list doubles as a to-do: fix the cause, run the import again, and only those are retried (see
/// `IPadImportService.discardImportedSource`) — and for files whose RAW develop failed.
private struct FileReasonList: View {
    let title: String
    let entries: [(name: String, reason: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries, id: \.name) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.callout.monospaced())
                            Text(entry.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 140)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

#Preview {
    IPadImportView(viewModel: SourceBrowserViewModel())
}
