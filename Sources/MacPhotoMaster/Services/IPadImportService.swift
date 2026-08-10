import Foundation
import MacPhotoMasterCore
import os

/// One file's outcome, whether it made it into the library or not.
struct IPadImportOutcome: Equatable {
    var sourceName: String
    /// `nil` when the file was skipped or failed — `reason` says which.
    var destinationURL: URL?
    var reason: String?
    /// The RAW-developed JPEG variant this import also produced, for a file the iPad marked with
    /// `RawDevelopService.developMarkerKeyword`. `nil` when it wasn't marked — or when the develop
    /// failed, which `developFailureReason` reports separately because the RAW itself still imported.
    var derivedDestinationURL: URL?
    var developFailureReason: String?

    var isImported: Bool { destinationURL != nil }
}

struct IPadImportSummary: Equatable {
    var outcomes: [IPadImportOutcome] = []

    var importedCount: Int { outcomes.filter(\.isImported).count }
    var developedCount: Int { outcomes.filter { $0.derivedDestinationURL != nil }.count }
    var failures: [IPadImportOutcome] { outcomes.filter { !$0.isImported } }
    var developFailures: [IPadImportOutcome] { outcomes.filter { $0.developFailureReason != nil } }
}

/// Finishes off files the iPad processed but couldn't complete, then moves them into the real
/// library — the Mac-initiated half of docs/SPEC.md §5's iPad divergence.
///
/// Two things the iPad can't do are made up for here. It has no `exiftool`, so
/// `PhotoAsset.artFilterToken` is always empty there and the art filter reaches neither the filename
/// nor the keywords; and its `ProcessMoveService` is built with `NativeMetadataWriter`, which parks
/// description/keywords/GPS in an XMP sidecar beside each file rather than writing into image bytes
/// ImageIO can't safely rewrite. So per file this reads the maker notes, reads the sidecar back, and
/// re-runs the ordinary `ProcessMoveService` with `ExifToolClient` — whose write of
/// title/description/keywords/GPS into the destination copy *is* the sidecar being folded in, and
/// whose `AutoMetadataRules` calls are what put the art filter into the keywords and the "In camera
/// effect" note into the description.
///
/// Lives in the app target rather than `MacPhotoMasterCore` because of that `ExifToolClient`
/// dependency — exiftool doesn't exist on iOS, so this could never run on the iPad side.
///
/// Getting the files onto the Mac is deliberately not this service's problem: it takes a local
/// folder, however it got there (Finder file sharing over USB, or the iPad's Files app sending them
/// to a share). Either way the iPad keeps its copy — Files turns a cross-provider Move into a Copy —
/// so clearing that end stays the user's job; this service only ever cleans up what it imported.
struct IPadImportService {
    private let exifTool = ExifToolClient()
    private let processMoveService = ProcessMoveService(metadataWriter: ExifToolClient())
    private let assetLoader = PhotoAssetLoader()

    /// Imports every supported file under `exportRoot` into `libraryRoot`, reporting each file's
    /// outcome as it goes via `onProgress` (completed count, total, latest outcome).
    ///
    /// A file whose sidecar is missing or unparseable is skipped and reported rather than imported
    /// bare: the description, keywords and GPS entered on the iPad exist *only* in that sidecar, so
    /// importing without it would silently discard the whole point of the iPad session. Same for a
    /// filename this app didn't generate. Skipped files are left untouched in `exportRoot`.
    func importAll(
        from exportRoot: URL, into libraryRoot: URL,
        onProgress: @Sendable @escaping (Int, Int, IPadImportOutcome) -> Void
    ) async throws -> IPadImportSummary {
        let assets = try await assetLoader.loadAssets(inTree: exportRoot)
        guard !assets.isEmpty else { return IPadImportSummary() }

        let makerNotes = await makerNoteFields(for: assets)

        Self.log.notice("Import started: \(assets.count) file(s) under \(exportRoot.path, privacy: .public)")
        var summary = IPadImportSummary()
        for asset in assets {
            let outcome = await importOne(
                asset, makerNotes: makerNotes[asset.url] ?? MakerNoteFields(), libraryRoot: libraryRoot)
            Self.log(outcome)
            summary.outcomes.append(outcome)
            onProgress(summary.outcomes.count, assets.count, outcome)
        }
        Self.log.notice(
            """
            Import finished: \(summary.importedCount)/\(summary.outcomes.count) imported, \
            \(summary.developedCount) developed, \(summary.failures.count) skipped, \
            \(summary.developFailures.count) develop failure(s)
            """)

        pruneEmptyDirectories(under: exportRoot)
        return summary
    }

    /// Filenames and reasons are logged `.public` deliberately: this is a local desktop app whose log
    /// is only useful if it names the file that failed, and the sheet's own list is gone the moment
    /// it closes. Read it back with
    /// `log show --predicate 'subsystem == "photos.briansmith.macphotomaster"' --last 1h`.
    private static let log = Logger(
        subsystem: "photos.briansmith.macphotomaster", category: "iPadImport")

    private static func log(_ outcome: IPadImportOutcome) {
        if let reason = outcome.reason {
            log.error("Skipped \(outcome.sourceName, privacy: .public): \(reason, privacy: .public)")
        }
        // Logged separately from `reason` because the file still imported — only its derivative
        // didn't, which is exactly the failure that used to leave no trace at all.
        if let developReason = outcome.developFailureReason {
            log.error(
                "RAW develop failed for \(outcome.sourceName, privacy: .public): \(developReason, privacy: .public)"
            )
        }
    }

    /// The maker-note fields only `exiftool` can recover on the Mac — the iPad's ImageIO reader
    /// sees none of them. `artFilterToken` drives the filename/keywords/description; `focusDistance`
    /// is the raw `Olympus:FocusDistance` display string (e.g. `"16.03 m"`), later parsed into the
    /// standard `EXIF:SubjectDistance` on write; `cameraLook` is the creative-dial settings, which
    /// `ProcessMoveService` renders to IPTC/XMP Instructions.
    private struct MakerNoteFields {
        var artFilterToken: String = ""
        var focusDistance: String = ""
        var cameraLook: CameraLook?
    }

    /// One batched `exiftool` invocation for the whole tree rather than one launch per file — the
    /// same reasoning as `SourceBrowserViewModel.loadArtFilterTokens(for:)`, where per-invocation
    /// Perl startup dominates the actual read.
    private func makerNoteFields(for assets: [PhotoAsset]) async -> [URL: MakerNoteFields] {
        let results = (try? await exifTool.readMetadata(at: assets.map(\.url))) ?? [:]
        return results.compactMapValues { result in
            guard case .success(let metadata) = result else { return nil }
            return MakerNoteFields(
                artFilterToken: ArtFilterTokenParsing.token(from: metadata),
                focusDistance: (metadata["Olympus:FocusDistance"] as? String) ?? "",
                cameraLook: CameraLookParsing.parse(from: metadata))
        }
    }

    private func importOne(_ asset: PhotoAsset, makerNotes: MakerNoteFields, libraryRoot: URL) async
        -> IPadImportOutcome
    {
        let sourceName = asset.url.lastPathComponent
        let sidecarURL = NativeMetadataWriter.sidecarURL(for: asset.url)

        let draft: StagedMetadataDraft
        do {
            guard let found = try SidecarDraftParsing.draft(at: sidecarURL) else {
                return IPadImportOutcome(
                    sourceName: sourceName, destinationURL: nil,
                    reason: "No \(sidecarURL.lastPathComponent) beside it — the iPad's description, keywords and GPS would be lost.")
            }
            draft = found
        } catch {
            return IPadImportOutcome(
                sourceName: sourceName, destinationURL: nil,
                reason: "Could not read \(sidecarURL.lastPathComponent): \(error.localizedDescription)")
        }

        guard let parsedName = IPadExportNameParsing.parse(filename: sourceName) else {
            return IPadImportOutcome(
                sourceName: sourceName, destinationURL: nil,
                reason: "Not a filename this app generated, so its sequence and batch can't be recovered.")
        }

        // The iPad can't develop a RAW itself, so it staged a marker keyword instead; this is where
        // that request is redeemed. It's stripped either way — it's this app's bookkeeping and must
        // never reach the library copy's keywords.
        let isMarkedForDevelop = RawDevelopService.isMarkedForDevelop(draft.keywords)

        var asset = asset
        asset.descriptionText = draft.description
        asset.keywords = RawDevelopService.removingDevelopMarker(from: draft.keywords)
        asset.artFilterToken = makerNotes.artFilterToken
        asset.cameraLook = makerNotes.cameraLook
        // Only readable here (exiftool sees the Olympus MakerNote the iPad's ImageIO reader can't);
        // ProcessMoveService parses it into the standard EXIF:SubjectDistance on the destination copy.
        asset.focusDistance = makerNotes.focusDistance
        // The pulled file carries no GPS of its own — nothing was ever written into it — so the
        // sidecar is the only source for a Timeline-derived fix.
        if let gps = draft.gps {
            asset.gpsLatitude = gps.latitude
            asset.gpsLongitude = gps.longitude
            asset.gpsAltitude = gps.altitude
        }

        let context = RenameContext(
            sourceURL: Self.sequenceOnlyURL(for: asset.url, sequence: parsedName.sequence),
            capturedAt: asset.capturedAt,
            cameraModel: asset.cameraModel,
            lensModel: asset.lensModel,
            batch: parsedName.batch,
            artFilterToken: makerNotes.artFilterToken)

        do {
            let result = try await processMoveService.processAndCopy(
                asset: asset, renameContext: context, libraryRoot: libraryRoot)
            // Develop before the source is trashed — it is the RAW being read.
            let developed = isMarkedForDevelop
                ? await developRAW(asset, sequence: parsedName.sequence, batch: parsedName.batch,
                    libraryRoot: libraryRoot)
                : (destinationURL: nil, failureReason: nil)
            discardImportedSource(at: asset.url, sidecarURL: sidecarURL)
            return IPadImportOutcome(
                sourceName: sourceName, destinationURL: result.destinationURL, reason: nil,
                derivedDestinationURL: developed.destinationURL,
                developFailureReason: developed.failureReason)
        } catch {
            return IPadImportOutcome(
                sourceName: sourceName, destinationURL: nil, reason: error.localizedDescription)
        }
    }

    /// Renders the marked RAW to a JPEG and puts that variant in the library beside it, carrying the
    /// same description/keywords/GPS the RAW just got plus the decoder token in the art-filter slot.
    ///
    /// A failure here is reported but doesn't fail the import: the RAW itself is already verified
    /// into the library by this point, and failing it would only mean a retry that can't reach the
    /// same file again. `derivedFrom` is what keeps `sooc` off a derivative — a developed file is
    /// emphatically not straight out of camera.
    private func developRAW(
        _ asset: PhotoAsset, sequence: String, batch: String, libraryRoot: URL
    ) async -> (destinationURL: URL?, failureReason: String?) {
        guard PhotoAssetLoader.isRaw(asset.url) else { return (nil, nil) }

        // App-created scratch that never held user data, removed rather than trashed — the same
        // documented exception `RawDevelopService.developViaDNG` makes for its intermediate DNG.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPadImportDevelop-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return (nil, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let renderURL = scratch
            .appendingPathComponent(asset.url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("jpg")

        do {
            let developed = try await RawDevelopService(dngConverter: AdobeDNGConverter())
                .develop(asset.url, to: renderURL)

            // Built from the rendered file's own EXIF rather than copied off the RAW's asset: the
            // render carries capture time, camera and lens through untouched, and reading them back
            // is what proves the derivative routes to the same day folder as its original.
            let reader = NativeMetadataReader()
            var derived = reader.mapToPhotoAsset(
                url: renderURL, metadata: try reader.readMetadata(at: renderURL))
            derived.derivedFrom = asset.url
            derived.descriptionText = asset.descriptionText
            derived.keywords = asset.keywords + [developed.token]
            derived.focusDistance = asset.focusDistance
            derived.gpsLatitude = asset.gpsLatitude
            derived.gpsLongitude = asset.gpsLongitude
            derived.gpsAltitude = asset.gpsAltitude

            // `artFilterToken` on the context but not on the asset: the token belongs in the
            // filename's art-filter slot, but a RAW carries no in-camera effect, so the
            // "In camera effect" description note must not fire.
            let context = RenameContext(
                sourceURL: Self.sequenceOnlyURL(for: renderURL, sequence: sequence),
                capturedAt: derived.capturedAt,
                cameraModel: derived.cameraModel,
                lensModel: derived.lensModel,
                batch: batch,
                artFilterToken: developed.token)

            let result = try await processMoveService.processAndCopy(
                asset: derived, renameContext: context, libraryRoot: libraryRoot)
            return (result.destinationURL, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// `RenameService` harvests the filename's sequence from *every* digit in the stem, which works
    /// on a camera-original name (`P1010042.ORF`) but not on one this app already built — the date
    /// and time baked into it would be absorbed into the sequence too. So the rename is handed a
    /// stand-in URL whose stem is just the recovered sequence; only `lastPathComponent` and
    /// `pathExtension` are ever read from it, and nothing opens it.
    private static func sequenceOnlyURL(for url: URL, sequence: String) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(sequence)
            .appendingPathExtension(url.pathExtension)
    }

    /// Only ever called once `ProcessMoveService` has verified the destination copy (size +
    /// SHA-256) and written its metadata, so the library copy is known good before the pulled one
    /// goes. Trash, never `removeItem`, per CLAUDE.md "File Safety".
    ///
    /// Because this runs only on success, re-running an import over the same folder sees just the
    /// files that failed last time — a partially failed run is safe to retry without duplicating
    /// anything into the library.
    private func discardImportedSource(at url: URL, sidecarURL: URL) {
        _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        _ = try? FileManager.default.trashItem(at: sidecarURL, resultingItemURL: nil)
    }

    /// Trashes directories the import emptied, deepest first so `<DD>/jpg/` going empty lets `<DD>/`
    /// and then `<M Month>/` go too. `root` itself is never trashed — the user picked it, and it's
    /// where anything skipped is still sitting.
    private func pruneEmptyDirectories(under root: URL) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }

        let directories = enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }

        for directory in directories {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard contents?.isEmpty == true else { continue }
            _ = try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
    }
}
