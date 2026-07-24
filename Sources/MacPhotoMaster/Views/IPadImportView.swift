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
                "Finishes files the iPad processed but could not complete: reads the in-camera effect from the maker notes, folds each XMP sidecar into its image, and moves everything into the library."
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
                HStack(spacing: 8) {
                    if viewModel.isImportingIPadExport {
                        ProgressView().controlSize(.small)
                    }
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = viewModel.iPadImportSummary, !summary.failures.isEmpty {
                SkippedFileList(failures: summary.failures)
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

/// The files that stayed behind, with the reason each one did. Left in the pulled folder rather than
/// imported, so this list doubles as a to-do: fix the cause, run the import again, and only these
/// are retried (see `IPadImportService.discardImportedSource`).
private struct SkippedFileList: View {
    let failures: [IPadImportOutcome]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skipped \(failures.count) file(s)")
                .font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(failures, id: \.sourceName) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.sourceName)
                                .font(.callout.monospaced())
                            Text(failure.reason ?? "Unknown reason")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
