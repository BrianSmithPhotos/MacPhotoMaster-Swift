import AppKit
import Foundation
import os
import MacPhotoMasterCore

/// Holds the currently-browsed folder's capture sets and the current selection. Views bind to
/// this via `@StateObject`/`@ObservedObject`; it owns no I/O itself — it kicks off `Service` calls
/// from a `Task` and republishes the results, per docs/ARCHITECTURE.md "Layers".
///
/// `@MainActor` on the class means every property and method here is main-actor-isolated by
/// default: SwiftUI reads `@Published` properties on the main thread, so this guarantees those
/// reads never race the writes below. It's also why `loadFolder` doesn't need to hop back to the
/// main actor explicitly after `await` — the compiler already knows this whole class runs there,
/// and only the `await loader.loadAssets(...)` line itself briefly suspends onto the service's
/// background task.
@MainActor
final class SourceBrowserViewModel: ObservableObject {
    @Published private(set) var captureSets: [CaptureSet] = []
    /// Capture sets skipped in the current folder — populated alongside `captureSets` in `load(_:)`
    /// and kept in sync by `skip(_:)`/`unskip(_:)`. Only ever shown by `SourcePanelView`'s
    /// "Skipped" segmented-filter view; not selectable for editing or process/move.
    @Published private(set) var skippedCaptureSets: [CaptureSet] = []
    /// Which of `captureSets`/`skippedCaptureSets` `SourcePanelView`'s grid currently displays.
    ///
    /// `didSet` re-focuses selection onto the first item of whichever list is now shown — without
    /// this, switching filters left the previous filter's selection/preview lingering (or nothing
    /// selected at all the first time `.skipped` is shown), rather than the grid and preview
    /// agreeing on what's focused.
    @Published var sourceViewFilter: SourceViewFilter = .active {
        didSet {
            guard sourceViewFilter != oldValue else { return }
            selectFirstTile()
        }
    }
    @Published private(set) var subfolders: [URL] = []
    /// The path from the folder the user opened down to the folder currently displayed — e.g.
    /// `[card, DCIM, 100OLYMP]`. Drives the breadcrumb bar; see docs/SPEC.md §1 "folder tree" and
    /// `FolderBrowser`'s doc comment for why this is breadcrumb navigation rather than a recursive
    /// tree.
    @Published private(set) var breadcrumb: [URL] = []
    @Published private(set) var isLoading = false
    @Published var loadErrorMessage: String?
    /// The single asset shown large in the center preview — always a member of whatever the grid
    /// or filmstrip most recently pointed at. See `multiSelectedIDs` for the separate batch-action
    /// selection.
    ///
    /// `didSet` resyncs the metadata edit buffer below to match whatever's now selected, discarding
    /// any unsaved in-progress edit on the previously-selected asset — there's no autosave-on-switch
    /// in this first pass, see `loadEditBuffer`.
    @Published var selectedAssetID: PhotoAsset.ID? {
        didSet {
            guard selectedAssetID != oldValue else { return }
            loadEditBuffer()
        }
    }

    /// Grid multi-selection (cmd-click toggles a tile, shift-click ranges from the last anchor) —
    /// docs/SPEC.md §1 "Manual multi-select". Always representative ids (one per capture set/single
    /// image tile in the grid); a plain click resets this to just that one tile. Drives the
    /// `.manualSelection` process/move scope and, via `refreshVariantStrip`, what the filmstrip
    /// under the preview shows.
    @Published private(set) var multiSelectedIDs: Set<PhotoAsset.ID> = []
    private var rangeAnchorID: PhotoAsset.ID?

    /// The full capture-group membership of the current grid selection (`SelectionScope.resolveScope`)
    /// — the filmstrip under the preview renders exactly this list, in this order.
    @Published private(set) var variantMemberIDs: [PhotoAsset.ID] = []
    /// Ring-selected subset of `variantMemberIDs` — starts equal to the full scope; cmd-click on a
    /// filmstrip tile narrows it (kept non-empty, mirroring the reference app). Not yet consumed by
    /// any action (there's no "Save Selected"/AI wiring in this app yet) — reserved for that.
    @Published private(set) var variantSelectedIDs: Set<PhotoAsset.ID> = []

    var hasMultiSelection: Bool { multiSelectedIDs.count > 1 }

    /// Where process/move (docs/SPEC.md §5) copies destination files under — picked once via a
    /// folder picker in `SourcePanelView` and persisted in `UserDefaults` so it's only asked for
    /// once rather than every process action; `setLibraryRoot` is also how the user changes it
    /// later. This app has no App Sandbox entitlement (no `.entitlements` file in the package), so
    /// a plain persisted path is enough — no security-scoped bookmark dance required.
    @Published private(set) var libraryRootURL: URL?
    @Published private(set) var isProcessing = false
    @Published var processStatusMessage: String?
    /// Files finished (successfully or not) and the scope's total, driving the determinate progress
    /// bar shown while `isProcessing`. Per-file granularity is as fine as this can get without
    /// `ProcessMoveService` reporting from inside a single copy — see `process(scope:libraryRoot:)`.
    @Published private(set) var processedFileCount = 0
    @Published private(set) var processTotalCount = 0

    /// State for `importIPadExport(from:)`, kept separate from `isProcessing`/`processStatusMessage`
    /// because the two run against different files entirely — the import reads a pulled folder, not
    /// the browsing session — and the import sheet is where its progress belongs.
    @Published private(set) var isImportingIPadExport = false
    @Published private(set) var iPadImportStatusMessage: String?
    /// Files imported so far and the pulled folder's total, driving the import sheet's determinate
    /// progress bar. Both stay 0 through the scan and the batched maker-note read, which run before
    /// `IPadImportService.importAll`'s per-file loop knows a total — the sheet shows an
    /// indeterminate spinner until the first callback arrives.
    @Published private(set) var iPadImportedFileCount = 0
    @Published private(set) var iPadImportTotalCount = 0
    /// Set once an import finishes, so the sheet can list what was skipped. `nil` while one is
    /// running or before the first run.
    @Published private(set) var iPadImportSummary: IPadImportSummary?

    /// The metadata panel's editable fields, kept as free text (parsed via `MetadataEditParsing` at
    /// save time) rather than typed properties so the view can bind `TextField`s directly. Synced
    /// to `selectedAsset`'s current values by `loadEditBuffer` whenever the selection changes. See
    /// docs/SPEC.md §2-3.
    ///
    /// There is no `editableTitle` — Title is not independently user-typed. It tracks
    /// `renamePreviewFilename` below instead, matching the reference app's `metadata_panel` (its
    /// `title_edit` gets overwritten by `_update_rename_preview` on every selection/location change,
    /// so it's effectively a live display of the eventual rename, not a separate saved field — see
    /// `_process_one` in `process_batch_mover.py`, which derives the title actually written to disk
    /// from the rename filename, never from a user-typed title). See [[feedback-follow-reference-app]].
    @Published var editableDescription: String = ""
    @Published var editableKeywords: String = ""

    /// The keywords `loadEditBuffer` put in `editableKeywords` for the current photo, so `suggestAI`
    /// can tell what the user has added by hand since (see `MetadataEditParsing.userAddedKeywords`).
    /// Deliberately not refreshed by the suggestion's own auto-save: a hint typed for this photo
    /// keeps steering repeat Suggest runs until the selection moves.
    private var loadedKeywords: [String] = []
    @Published var editableLatitudeText: String = ""
    @Published var editableLongitudeText: String = ""
    @Published private(set) var isSavingMetadata = false
    @Published var saveStatusMessage: String?

    /// Status text for the Timeline-derived GPS suggestion (docs/SPEC.md §7) shown under the
    /// lat/long fields — e.g. "Nearest GPS 3m 20s away (GPS, accuracy 12m)". Set by
    /// `suggestGPSIfNeeded()` or by reverse-geocode keyword lookup; cleared on every selection
    /// change by `loadEditBuffer()` so a message from one photo never lingers under another.
    @Published var gpsSuggestionStatusMessage: String?

    /// True while a manually-triggered `refreshTimeline()` Drive sync/import is in flight —
    /// disables the "Refresh Timeline" button so it can't be fired twice concurrently.
    @Published private(set) var isSyncingTimeline = false

    /// Result text for a manually-triggered `refreshTimeline()` — e.g. "Imported 214 Timeline
    /// points." or "Timeline is already up to date." The silent per-launch/per-folder-load sync
    /// (`syncAndImportTimelineIfNeeded()`) never touches this; it's only for the explicit button.
    @Published var timelineSyncStatusMessage: String?

    /// True while `refreshAltitude()` has an elevation lookup in flight — disables the manual
    /// refresh button so a slow/timed-out USGS EPQS call can't be fired twice concurrently.
    @Published private(set) var isLookingUpAltitude = false

    /// AI vision model used for AI-assisted description/keyword suggestions (docs/SPEC.md §6), in
    /// `"<provider>:<model>"` form (see `AIModelSelection`) — editable so the user can point at any
    /// pulled Ollama model or OpenRouter model id without a rebuild.
    @Published var aiModelText: String = AIModelSelection.presets[0]
    /// True while `suggestAI()` has a request (and its immediate auto-save) in flight — disables
    /// the Suggest button so a slow local-model response can't be fired twice concurrently.
    @Published private(set) var isSuggestingAI = false
    @Published var aiStatusMessage: String?
    /// The exact image the last `suggestAI()` call sent to the model (post `SubjectIsolationService`
    /// crop, when one was found) — shown in the Metadata panel so a misidentification is diagnosable
    /// (was the model looking at the subject, or a diluted full frame?).
    ///
    /// Populated on every suggestion, including the uncropped full-frame case. That looks redundant
    /// next to the big preview, but isn't: the preview shows `selectedAsset` (the capture set's
    /// JPEG-first representative) while the AI is sent `AISuggestionSourcePicker`'s pick (the RAW),
    /// so the two can be different files — and a description of something not visible in the preview
    /// is otherwise indistinguishable from a hallucination. See `aiEvaluatedImageSourceName`.
    @Published private(set) var aiEvaluatedImage: CGImage?
    /// Filename of the asset `aiEvaluatedImage` was decoded from, shown alongside it so the
    /// preview-vs-sent file distinction above is visible rather than inferred.
    @Published private(set) var aiEvaluatedImageSourceName: String?
    /// User-drawn override for the subject crop (image-pixel space, matching the 2048px-cap decode
    /// `extractPreviewAsync` produces), set by dragging a rectangle on `PreviewPanelView`'s big
    /// preview. When present, it's used in place of `SubjectIsolationService`'s AI-computed crop —
    /// both for the eager `aiEvaluatedImage` preview and for the next `suggestAI()` call. Cleared on
    /// every selection change by `loadEditBuffer()`, same lifetime as `aiEvaluatedImage`.
    @Published private(set) var manualSubjectCropRect: CGRect?
    /// Handle to the in-flight eager crop computation kicked off by `setSubjectIsolationEnabled`/
    /// `setManualCropRect`/a selection change — cancelled and replaced on every retrigger so a slow
    /// Vision request for a since-abandoned photo can't clobber `aiEvaluatedImage` after the fact.
    private var subjectCropTask: Task<Void, Never>?
    /// Handle to the in-flight `suggestAI()` `Task`, kept only so `cancelAISuggestion()` has
    /// something to cancel — added because the native MLX backend has no request-level timeout
    /// (a hung/OOM-prone local generation can otherwise spin indefinitely with no way to abort it
    /// short of quitting the app). `MLXNativeProvider.chat` checks `Task.isCancelled` cooperatively,
    /// same mechanism `mlx-swift-lm`'s own token loop uses internally.
    private var suggestAITask: Task<Void, Never>?

    /// OpenRouter model strings (matching the `"<provider>:<model>"` convention `aiModelText` uses,
    /// e.g. `"openrouter:google/gemini-3.5-flash"`) for which the eBird candidate species list is
    /// withheld from the prompt. The candidate list is extra input-token cost on every request; for
    /// the free local Ollama/MLX providers that's irrelevant, so those always get it (never added
    /// here), but for a few flagship pay-per-token models the user judged the accuracy gain isn't
    /// worth the added cost by default. Persisted in `UserDefaults`; `SettingsView` exposes a
    /// per-model Toggle via `setEBirdCandidateListEnabled(_:forModel:)`.
    @Published private(set) var eBirdDisabledModels: Set<String>

    /// Whether `suggestAI()` crops to a detected subject before sending the image to the AI — either
    /// `SubjectIsolationService`'s AI-picked crop, or `manualSubjectCropRect` when the user's drawn an
    /// override on `PreviewPanelView`'s big preview. Good for a small/distant subject (e.g. a bird or
    /// flower) filling little of the frame; bad for a general scene (e.g. a street shot), where the AI
    /// crop can pick an incidental foreground object — a parked car, a lamp-post — instead of the
    /// scene the user meant to describe. Off by default; the user flips it on for a close-subject
    /// session and back off for general shooting. Persisted in `UserDefaults`; `MetadataPanelView`
    /// exposes it as a Toggle next to the AI model picker (a per-session choice, not a rarely-touched
    /// preference, so it lives there rather than `SettingsView`). Turning it on (or switching photos
    /// while it's already on) eagerly computes and shows the crop via `recomputeSubjectCropPreview()`
    /// rather than waiting for a `suggestAI()` call.
    @Published private(set) var subjectIsolationEnabled: Bool

    /// Whether the camera-look strip is drawn over the preview (docs/SPEC.md "Ideas, not started").
    /// Off by default and persisted: it covers part of the photo, so it's a thing the user reaches
    /// for when reading a look rather than something that should be in the way while culling.
    @Published private(set) var lookVisualiserEnabled: Bool

    /// Off-by-default set as of 2026-07-05 — the user's call, not derived from anything measurable;
    /// revisit if the OpenRouter preset list (`AIModelSelection.presets`) changes these model names.
    static let defaultEBirdDisabledModels: Set<String> = [
        "openrouter:google/gemini-3.5-flash",
        "openrouter:anthropic/claude-opus-4.8",
        "openrouter:openai/gpt-5.5",
        "openrouter:openai/gpt-5.6-luna",
        "openrouter:anthropic/claude-sonnet-5",
    ]

    private let loader = PhotoAssetLoader()
    private let folderBrowser = FolderBrowser()
    private let grouping = CaptureGroupingService()
    private let exifTool = ExifToolClient()
    private let processMoveService = ProcessMoveService(metadataWriter: ExifToolClient())
    private let renameService = RenameService()
    private let timelineImportParser = TimelineImportParser()
    private let elevationService = ElevationLookupService()
    private let reverseGeocodeService = ReverseGeocodeService()
    private let ebirdService = EBirdSpeciesListService()
    private let ollamaProvider: AIProvider = OllamaProvider()
    private let openRouterProvider: AIProvider = OpenRouterProvider()
    private let mlxProvider: AIProvider = MLXNativeProvider()
    private let foundationProvider: AIProvider = FoundationModelsProvider()
    private let aiSuggestionService = AISuggestionService()
    /// Where RAW-developed JPEGs are staged. `nil` only if Application Support is unwritable, in
    /// which case Develop RAW is simply unavailable rather than the folder failing to load.
    ///
    /// Unlike the SQLite-backed stores below this needs no `ensure…` accessor: its init only creates
    /// a directory, cheap enough to do up front, and `load(_:)` needs it synchronously.
    private let rawDerivedStore: RawDerivedStore? = try? RawDerivedStore.makeDefault()

    /// RAW originals whose staged derivative has been copied into the library but is deliberately
    /// still on disk, together with the folder that was open when they were processed. See
    /// `discardSpentDerivatives(for:inFolder:processedPaths:)` for why the cleanup waits.
    private var keptDerivativeOriginals: Set<URL> = []
    private var keptDerivativeFolderPath: String?

    private static let ebirdLogger = Logger(subsystem: "MacPhotoMaster", category: "EBirdSpecies")

    /// Shares `IPadImportService`'s subsystem so one predicate catches both write paths:
    /// `log show --predicate 'subsystem == "photos.briansmith.macphotomaster"' --last 1h`.
    /// Filenames and reasons are logged `.public` for the same reason they are there — default
    /// redaction renders them `<private>`, which makes a local desktop app's log useless for the one
    /// question it needs to answer.
    private static let saveLog = Logger(
        subsystem: "photos.briansmith.macphotomaster", category: "MetadataSave")

    /// Reverse-geocode context text (docs/SPEC.md §6/§7), keyed by capture-set representative id so
    /// `suggestAI()` can pass along location context for whichever set it's sourcing the AI image
    /// from. Populated by `lookupLocationKeywordsIfNeeded()`.
    private var locationContextByRepresentativeID: [PhotoAsset.ID: String] = [:]
    /// eBird candidate-species list text (see `EBirdCandidateFormatting`/`AISuggestionService`'s doc
    /// comment for why), keyed the same way as `locationContextByRepresentativeID` and populated
    /// alongside it since both come from the same GPS fix. Not part of docs/SPEC.md or the reference
    /// app — added to improve wildlife identification accuracy beyond a single generic prompt.
    private var birdCandidateSpeciesByRepresentativeID: [PhotoAsset.ID: String] = [:]
    /// Region common-name -> Latin binomial, mirroring the iPad. Used to post-hoc-validate the
    /// `foundation:` provider's typed species guess (see `EBirdCandidateFormatting.regionalScientificName`)
    /// and to attach binomials, since that provider is sent no candidate list to work from.
    private var birdScientificNamesByRepresentativeID: [PhotoAsset.ID: [String: String]] = [:]

    /// The reverse geocode's city/county/state keywords, kept per capture set. The selected set puts
    /// these straight into the edit buffer, from where a save carries them to the file; a batch run
    /// has no buffer to put them in, so it needs them back out of here to fold into what it writes.
    private var locationKeywordsByRepresentativeID: [PhotoAsset.ID: [String]] = [:]
    /// Guards against re-querying Nominatim for the same capture set more than once per session —
    /// mirrors the reference app's `_geocode_auto_applied_paths`.
    private var geocodeAppliedRepresentativeIDs: Set<PhotoAsset.ID> = []

    /// The manual per-session label `RenameService` needs for its filename pattern (docs/SPEC.md
    /// §4) — not GPS-derived, so it lives here rather than on `PhotoAsset`. Defaults to empty, in
    /// which case `RenameService` just omits the batch segment.
    ///
    /// `didSet` recomputes `renamePreviewFilename` immediately, so the Title field the user sees
    /// updates live as they type a batch label — same as the reference app's
    /// `location_edit.textChanged` -> `_update_rename_preview` wiring.
    @Published var sessionBatch: String = "" {
        didSet {
            guard sessionBatch != oldValue else { return }
            updateRenamePreview()
        }
    }

    /// Live preview of the filename `RenameService` would generate for `selectedAsset` right now —
    /// recomputed by `updateRenamePreview()` whenever the selection or `sessionBatch` changes.
    /// Uniqueness here is only checked against the *source* folder's existing names (a fast,
    /// dependency-free preview, same as the reference app's `_update_rename_preview`); the
    /// authoritative check against the real destination folder happens at process time in
    /// `ProcessMoveService`, so this can differ from the final name in rare collision cases.
    @Published private(set) var renamePreviewFilename: String = ""

    /// What the Title field displays — the rename preview's filename stem, not a separately typed
    /// or saved value. See the note on `editableDescription` above for why there's no `editableTitle`.
    var titlePreview: String { (renamePreviewFilename as NSString).deletingPathExtension }

    private static let libraryRootDefaultsKey = "libraryRootPath"
    private static let sourceRootDefaultsKey = "sourceRootPath"
    private static let eBirdDisabledModelsDefaultsKey = "eBirdDisabledModels"
    private static let subjectIsolationEnabledDefaultsKey = "subjectIsolationEnabled"
    private static let lookVisualiserEnabledDefaultsKey = "lookVisualiserEnabled"
    /// Falls back to the user's SD card mount point when no source folder has ever been opened.
    /// The card is swapped for a new one roughly every 10K images, far less often than the app is
    /// launched, so defaulting to (and, via `openFolder`, persisting) whatever was last opened
    /// saves an "Open Folder…" click on almost every launch.
    private static let defaultSourceRootPath = "/Volumes/OM SYSTEM/DCIM/105OMSYS/"

    init() {
        if let stored = UserDefaults.standard.array(forKey: Self.eBirdDisabledModelsDefaultsKey)
            as? [String]
        {
            eBirdDisabledModels = Set(stored)
        } else {
            eBirdDisabledModels = Self.defaultEBirdDisabledModels
        }
        subjectIsolationEnabled =
            UserDefaults.standard.bool(forKey: Self.subjectIsolationEnabledDefaultsKey)
        lookVisualiserEnabled =
            UserDefaults.standard.bool(forKey: Self.lookVisualiserEnabledDefaultsKey)
        if let path = UserDefaults.standard.string(forKey: Self.libraryRootDefaultsKey) {
            libraryRootURL = URL(fileURLWithPath: path)
        }
        let sourceRootPath =
            UserDefaults.standard.string(forKey: Self.sourceRootDefaultsKey) ?? Self.defaultSourceRootPath
        // `openFolder` -> `load(_:)` already triggers `syncAndImportTimelineIfNeeded()`, covering
        // the launch-time sync too.
        openFolder(at: URL(fileURLWithPath: sourceRootPath))
    }

    /// Called from the library-folder picker, both on first pick and on later changes.
    func setLibraryRoot(_ url: URL) {
        libraryRootURL = url
        UserDefaults.standard.set(url.path, forKey: Self.libraryRootDefaultsKey)
    }

    /// Called from `SettingsView`'s per-model Toggle — see `eBirdDisabledModels`'s doc comment.
    func setEBirdCandidateListEnabled(_ enabled: Bool, forModel model: String) {
        if enabled {
            eBirdDisabledModels.remove(model)
        } else {
            eBirdDisabledModels.insert(model)
        }
        UserDefaults.standard.set(
            Array(eBirdDisabledModels), forKey: Self.eBirdDisabledModelsDefaultsKey)
    }

    /// Called from the preview's look-strip button and its ⌘L shortcut.
    func setLookVisualiserEnabled(_ enabled: Bool) {
        lookVisualiserEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.lookVisualiserEnabledDefaultsKey)
    }

    /// Called from `MetadataPanelView`'s subject-crop Toggle — see `subjectIsolationEnabled`'s doc
    /// comment. Eagerly computes and shows the crop (AI or manual, whichever applies) the moment the
    /// toggle is switched on, rather than waiting for a `suggestAI()` call.
    func setSubjectIsolationEnabled(_ enabled: Bool) {
        subjectIsolationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.subjectIsolationEnabledDefaultsKey)
        if enabled {
            recomputeSubjectCropPreview()
        } else {
            subjectCropTask?.cancel()
            aiEvaluatedImage = nil
            aiEvaluatedImageSourceName = nil
        }
    }

    /// Called from `PreviewPanelView`'s drag-to-crop overlay on the big preview — `rect` (image-pixel
    /// space) on drag commit, `nil` to reset back to the AI-computed crop. See
    /// `manualSubjectCropRect`'s doc comment.
    func setManualCropRect(_ rect: CGRect?) {
        manualSubjectCropRect = rect
        recomputeSubjectCropPreview()
    }

    /// Shared by `setSubjectIsolationEnabled`, `setManualCropRect`, and a selection change: (re)runs
    /// whichever crop currently applies — the manual override if one's set, otherwise
    /// `SubjectIsolationService`'s AI crop — against the currently selected asset, and publishes the
    /// result to `aiEvaluatedImage` for the "Evaluated" preview. No-op (and clears the preview) when
    /// the toggle is off or nothing's selected.
    private func recomputeSubjectCropPreview() {
        subjectCropTask?.cancel()
        guard subjectIsolationEnabled, let asset = selectedAsset else {
            aiEvaluatedImage = nil
            aiEvaluatedImageSourceName = nil
            return
        }
        let id = asset.id
        let manualRect = manualSubjectCropRect
        subjectCropTask = Task {
            guard let cgImage = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url)
            else { return }
            guard !Task.isCancelled, selectedAssetID == id else { return }
            let cropped: CGImage?
            if let manualRect {
                cropped = cgImage.cropping(to: manualRect)
            } else {
                cropped = await computeSubjectCrop(in: cgImage)
            }
            guard !Task.isCancelled, selectedAssetID == id else { return }
            aiEvaluatedImage = cropped
            aiEvaluatedImageSourceName = asset.url.lastPathComponent
        }
    }

    /// Runs `SubjectIsolationService.isolateSubject` off the main actor — it's a blocking synchronous
    /// Vision request, and this is now invoked on every toggle flip and every crop-rectangle drag
    /// commit (not just on a `suggestAI()` click), so leaving it on `MainActor` would jank the preview
    /// while dragging.
    private func computeSubjectCrop(in image: CGImage) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            SubjectIsolationService.isolateSubject(in: image)
        }.value
    }

    /// Lazily created on first use rather than in `init` because `SkipStateStore.init` is
    /// throwing (it touches the filesystem to open/migrate the database) and `SourceBrowserViewModel`
    /// is constructed synchronously by SwiftUI (`@StateObject`). Cached after the first successful
    /// creation so every folder load doesn't reopen the database.
    private var skipStore: SkipStateStore?

    /// The folder a just-loaded `CaptureSet` belongs to, keyed by set id — needed by `skip(_:)`
    /// since by the time the user acts, `breadcrumb.last` may already point at a different folder
    /// (they could have navigated on).
    private var folderPathByCaptureSetID: [CaptureSet.ID: String] = [:]

    /// The current folder's capture groups as `CaptureGroupingService` produced them from the
    /// camera's own signals, before the user's manual merges and before skip state divides them up.
    /// This, `mergeIDsByAssetPath` and `skippedPaths` are the source of truth; everything the
    /// browser displays is re-derived from them by `rederiveCaptureSets()`, never edited directly.
    /// Skipping is per file, so a change can move part of a set across the divide without moving the
    /// set — which splicing whole sets between the two published arrays can't express.
    private var automaticCaptureSets: [CaptureSet] = []
    private var mergeIDsByAssetPath: [String: String] = [:]
    private var skippedPaths: Set<String> = []

    /// `automaticCaptureSets` with the user's manual merges applied — the grouping the browser
    /// actually works in, and what skip state is partitioned over.
    private var groupedCaptureSets: [CaptureSet] = []

    /// Called from the "Open Folder…" picker (and from `init` to reopen last time's root) — starts
    /// a fresh breadcrumb rooted at the chosen folder, discarding anything previously open, and
    /// persists `folderURL` as the new default source root so the next launch starts here too. The
    /// picker is only ever expected to change roots roughly every 10K images, so it's cheap to
    /// re-persist the same path most of the time this is called from `init`.
    func openFolder(at folderURL: URL) {
        UserDefaults.standard.set(folderURL.path, forKey: Self.sourceRootDefaultsKey)
        breadcrumb = [folderURL]
        load(folderURL)
    }

    /// Called when the user clicks a subfolder tile or a breadcrumb segment. Clicking an ancestor
    /// already in the breadcrumb truncates back to it (like clicking a Finder path-bar segment);
    /// clicking a subfolder appends one level.
    func navigate(to folderURL: URL) {
        if let index = breadcrumb.firstIndex(of: folderURL) {
            breadcrumb.removeSubrange((index + 1)...)
        } else {
            breadcrumb.append(folderURL)
        }
        load(folderURL)
    }

    /// Fire-and-forget from the View's perspective: starts an unstructured `Task` so the caller
    /// (a SwiftUI button/tap action) doesn't need to be `async` itself. Re-entrant calls just
    /// replace whatever the previous load was populating.
    ///
    /// The two `async let`s run concurrently — unlike `Task { }`, `async let` creates a
    /// *structured* child task: it's automatically awaited (and cancelled, if this enclosing
    /// `Task` is cancelled) by the time this scope exits, so there's no separate lifetime to
    /// manage the way there would be with two unstructured `Task { }`s.
    ///
    /// `preservingSelection` is for a reload triggered by an action on the folder already being
    /// shown (developing a RAW, processing a derivative away) rather than by navigation: those must
    /// not throw the user back to the first tile of a folder they were part-way through reviewing.
    private func load(_ folderURL: URL, preservingSelection: Bool = false) {
        isLoading = true
        loadErrorMessage = nil
        Task { await syncAndImportTimelineIfNeeded() }
        Task {
            defer { isLoading = false }
            let previousSelectionID = preservingSelection ? selectedAssetID : nil
            do {
                async let assetsTask = loader.loadAssets(in: folderURL)
                async let subfoldersTask = folderBrowser.subfolders(of: folderURL)
                let (assets, folders) = try await (assetsTask, subfoldersTask)
                skippedPaths = await skippedAssetPaths(inFolder: folderURL)
                processedAssetPaths = await loadProcessedAssetPaths(inFolder: folderURL)
                discardSpentDerivatives(
                    for: assets, inFolder: folderURL, processedPaths: processedAssetPaths)
                // RAW-developed JPEGs live in app storage rather than this folder, so they're
                // merged in before grouping. Their EXIF capture time came through the render
                // untouched, which is what puts each one in its original's capture set.
                let derived = rawDerivedStore?.derivedAssets(forOriginals: assets) ?? []
                // The camera's own burst/bracket counter lives in the maker notes, and nothing else
                // can separate a burst from two deliberate presses in the same second.
                let signals = await groupingSignals(for: assets.map(\.url))
                let allSets = grouping.group(assets + derived, signals: signals)
                automaticCaptureSets = allSets
                mergeIDsByAssetPath = await mergeIDs(inFolder: folderURL)
                rederiveCaptureSets()
                folderPathByCaptureSetID = Dictionary(
                    uniqueKeysWithValues: allSets.map { ($0.id, folderURL.path) })
                subfolders = folders
                if let previousSelectionID,
                    displayedCaptureSets.flatMap(\.members).contains(where: { $0.id == previousSelectionID })
                {
                    // Only assign when it actually changed: `selectedAssetID`'s `didSet` resets the
                    // metadata edit buffer, which would silently discard anything typed into the
                    // form while the develop that triggered this reload was running.
                    if selectedAssetID != previousSelectionID {
                        selectedAssetID = previousSelectionID
                    }
                    refreshVariantStrip()
                } else {
                    selectFirstTile()
                }
            } catch {
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    /// One narrow exiftool pass over the folder, with the file's own bytes covering whatever it
    /// didn't answer for. On the Mac that second step does nothing; on the iPad, where exiftool
    /// cannot run at all, it is the only step — and grouping there has been falling back to the
    /// timestamp gap, which cannot tell a burst from two presses in one second.
    ///
    /// Written as a fill-in rather than a choice of reader so one unreadable file is handled the
    /// same way as a whole platform. Still best-effort: a file neither can read stays absent, and
    /// grouping treats it as unknown rather than as a boundary.
    private func groupingSignals(for urls: [URL]) async -> [URL: CaptureSignals] {
        var signals = (try? await exifTool.readGroupingSignals(at: urls)) ?? [:]
        let missing = urls.filter { signals[$0] == nil }
        guard !missing.isEmpty else { return signals }
        for (url, native) in await OlympusMakerNoteReader.signals(at: missing) { signals[url] = native }
        return signals
    }

    /// Hides every member of `captureSet` from the active view and persists that choice so it
    /// stays hidden if this folder is reopened later — moves it into `skippedCaptureSets`, visible
    /// via `SourcePanelView`'s "Skipped" filter and restorable with `unskip(_:)`. Never touches the
    /// files on disk — see `SkipStateStore`'s doc comment for why "skip" is view-only.
    func skip(_ captureSet: CaptureSet) {
        setSkipped(true, assets: captureSet.members, inGroup: captureSet)
    }

    /// Restores `captureSet` from `skippedCaptureSets` back into the active `captureSets` — the
    /// inverse of `skip(_:)`, reachable only via `SourcePanelView`'s "Skipped" filter's context-menu
    /// "Un-skip" action (never a side effect of previewing/clicking a tile there).
    func unskip(_ captureSet: CaptureSet) {
        setSkipped(false, assets: captureSet.members, inGroup: captureSet)
    }

    /// Skips one image out of its capture set, leaving the set's other members in the active view —
    /// the filmstrip's per-file counterpart to `skip(_:)`, for culling individual frames out of a
    /// focus bracket or a burst rather than discarding the whole sequence. The skipped frame shows
    /// up under the "Skipped" filter alongside its own set's other culled members.
    func skipMember(_ asset: PhotoAsset) {
        guard let group = group(containing: asset.id) else { return }
        setSkipped(true, assets: [asset], inGroup: group)
    }

    /// Returns one culled image to its capture set — the inverse of `skipMember(_:)`, reached from
    /// the filmstrip while browsing the "Skipped" filter.
    func unskipMember(_ asset: PhotoAsset) {
        guard let group = group(containing: asset.id) else { return }
        setSkipped(false, assets: [asset], inGroup: group)
    }

    /// The grouped capture sets the grid's multi-selection covers, in display order. Resolved back
    /// to the grouping rather than read off `displayedCaptureSets`, so a set with some members
    /// skipped is merged whole rather than losing its culled frames.
    private var multiSelectedGroups: [CaptureSet] {
        let selectedIDs = Set(
            displayedCaptureSets.filter { set in
                set.representative.map { multiSelectedIDs.contains($0.id) } ?? false
            }.map(\.id))
        return groupedCaptureSets.filter { selectedIDs.contains($0.id) }
    }

    /// Whether "Merge into One Capture Set" has anything to act on — two or more sets picked in the
    /// grid.
    var canMergeSelection: Bool { multiSelectedGroups.count > 1 }

    /// Whether this set is one the user merged by hand, i.e. whether it can be split apart again.
    func isMerged(_ captureSet: CaptureSet) -> Bool {
        captureSet.members.contains { mergeIDsByAssetPath[$0.url.path] != nil }
    }

    /// Combines every capture set in the grid multi-selection into one, and remembers the choice for
    /// this folder. For captures the camera left no counter behind for — a long hand-shot sequence,
    /// an interval run on a body that stamps no interval index — where only the photographer knows
    /// the frames belong together. See `CaptureSetMerging`.
    func mergeSelectedCaptureSets() {
        let groups = multiSelectedGroups
        guard groups.count > 1, let folderPath = folderPathByCaptureSetID[groups[0].id] else { return }
        let assetPaths = groups.flatMap { $0.members.map(\.url.path) }
        let previousIndex = displayedCaptureSets.firstIndex { $0.id == groups[0].id } ?? 0
        Task {
            guard let store = await ensureMergeStore(),
                let mergeID = try? await store.merge(assetPaths: assetPaths, inFolder: folderPath)
            else { return }
            for path in assetPaths { mergeIDsByAssetPath[path] = mergeID }
            rederiveCaptureSets()
            reconcileSelection(afterChangeTo: groups[0].id, previousIndex: previousIndex)
        }
    }

    /// Undoes a manual merge, letting the camera's own grouping stand again — the inverse of
    /// `mergeSelectedCaptureSets()`.
    func splitApart(_ captureSet: CaptureSet) {
        guard let folderPath = folderPathByCaptureSetID[captureSet.id],
            let group = groupedCaptureSets.first(where: { $0.id == captureSet.id })
        else { return }
        let assetPaths = group.members.map(\.url.path)
        let previousIndex = displayedCaptureSets.firstIndex { $0.id == group.id } ?? 0
        Task {
            guard let store = await ensureMergeStore() else { return }
            try? await store.unmerge(assetPaths: assetPaths, inFolder: folderPath)
            for path in assetPaths { mergeIDsByAssetPath.removeValue(forKey: path) }
            rederiveCaptureSets()
            reconcileSelection(afterChangeTo: group.id, previousIndex: previousIndex)
        }
    }

    /// Persists a skip-state change for `assets` and republishes both lists from the new partition.
    ///
    /// Everything is re-derived from `groupedCaptureSets`/`skippedPaths` rather than spliced between
    /// the two published arrays: a per-file skip can move part of a set without moving the set, and
    /// re-deriving is the only way that stays consistent whichever members are involved. `inGroup`
    /// is the *grouped* set the change belongs to (`captureSets`' entries carry their group's id, so
    /// either half can be passed straight in) — it names the folder to persist against, and the tile
    /// selection should land on if the change empties the one being viewed.
    private func setSkipped(_ isSkipped: Bool, assets: [PhotoAsset], inGroup group: CaptureSet) {
        guard let folderPath = folderPathByCaptureSetID[group.id] else { return }
        let assetPaths = assets.map(\.url.path)
        Task {
            guard let store = await ensureSkipStore() else { return }
            if isSkipped {
                try? await store.skip(assetPaths: assetPaths, inFolder: folderPath)
                skippedPaths.formUnion(assetPaths)
            } else {
                try? await store.unskip(assetPaths: assetPaths, inFolder: folderPath)
                skippedPaths.subtract(assetPaths)
            }

            // Read before re-partitioning, while the displayed list is still the one the user acted on.
            let previousIndex = displayedCaptureSets.firstIndex { $0.id == group.id } ?? 0
            rederiveCaptureSets()
            reconcileSelection(afterChangeTo: group.id, previousIndex: previousIndex)
        }
    }

    /// Rebuilds everything the browser shows from the three stored inputs: the camera's grouping,
    /// the user's manual merges on top of it, then the split into active and skipped.
    private func rederiveCaptureSets() {
        groupedCaptureSets = CaptureSetMerging.apply(
            automaticCaptureSets, mergeIDsByAssetPath: mergeIDsByAssetPath)
        let partition = SkipPartition.split(groupedCaptureSets, skippedPaths: skippedPaths)
        captureSets = partition.active
        skippedCaptureSets = partition.skipped
    }

    private func group(containing assetID: PhotoAsset.ID) -> CaptureSet? {
        groupedCaptureSets.first { $0.members.contains { $0.id == assetID } }
    }

    /// Re-points the selection after a skip/un-skip re-partitioned the lists, in three cases: the
    /// selected image is still on screen (a sibling was skipped, so nothing needs to move); it isn't,
    /// but its set survives with fewer members (the representative itself was skipped, so focus moves
    /// to whichever member represents the set now); or the set has left the displayed list entirely
    /// (focus moves to the next set, as it did when skip only ever worked a whole set at a time).
    private func reconcileSelection(afterChangeTo groupID: CaptureSet.ID, previousIndex: Int) {
        let displayed = displayedCaptureSets
        multiSelectedIDs = multiSelectedIDs.filter { id in
            displayed.contains { $0.representative?.id == id }
        }

        if displayed.contains(where: { set in set.members.contains { $0.id == selectedAssetID } }) {
            refreshVariantStrip()
        } else if let survivor = displayed.first(where: { $0.id == groupID }),
            let representativeID = survivor.representative?.id
        {
            selectedAssetID = representativeID
            multiSelectedIDs.insert(representativeID)
            rangeAnchorID = representativeID
            refreshVariantStrip()
        } else {
            selectTileAfterRemoval(from: displayed, previousIndex: previousIndex)
        }
    }

    /// Selects the first tile in whichever list `sourceViewFilter` currently displays (or clears
    /// selection if that list is empty), resetting the multi-selection and filmstrip to match. Used
    /// on a fresh folder load and whenever `sourceViewFilter` changes, so the grid and the preview
    /// always agree on what's focused.
    private func selectFirstTile() {
        guard let id = displayedCaptureSets.first?.representative?.id else {
            selectedAssetID = nil
            multiSelectedIDs = []
            rangeAnchorID = nil
            refreshVariantStrip()
            return
        }
        selectedAssetID = id
        multiSelectedIDs = [id]
        rangeAnchorID = id
        refreshVariantStrip()
    }

    /// Selects whichever capture set now sits at `previousIndex` in `sets` — the set that took the
    /// just-removed set's place, i.e. the *next* one in capture order, since `skip(_:)`/`unskip(_:)`
    /// remove without re-sorting. Falls back to the new last set if the removed one was last, or
    /// clears selection if `sets` is now empty. Shared by `skip(_:)` (passing `captureSets`) and
    /// `unskip(_:)` (passing `skippedCaptureSets`) so focus stays near where the user was working
    /// instead of jumping back to the first tile in the folder.
    private func selectTileAfterRemoval(from sets: [CaptureSet], previousIndex: Int) {
        guard !sets.isEmpty else {
            selectedAssetID = nil
            multiSelectedIDs = []
            rangeAnchorID = nil
            refreshVariantStrip()
            return
        }
        let index = min(previousIndex, sets.count - 1)
        guard let id = sets[index].representative?.id else {
            selectFirstTile()
            return
        }
        selectedAssetID = id
        multiSelectedIDs = [id]
        rangeAnchorID = id
        refreshVariantStrip()
    }

    /// Whichever of `captureSets`/`skippedCaptureSets` `sourceViewFilter` currently displays —
    /// selection, range/multi-select, and the filmstrip all operate against this so browsing the
    /// Skipped filter previews and (multi-)selects within that list exactly like the Active filter
    /// does, without any of it touching skip state.
    private var displayedCaptureSets: [CaptureSet] {
        switch sourceViewFilter {
        case .active: return captureSets
        case .skipped: return skippedCaptureSets
        }
    }

    /// Maps every asset id (within `displayedCaptureSets`) to its full capture-group membership
    /// (including itself) — the lookup `SelectionScope`'s pure functions need but don't own
    /// themselves.
    private var membersByAssetID: [PhotoAsset.ID: [PhotoAsset.ID]] {
        var map: [PhotoAsset.ID: [PhotoAsset.ID]] = [:]
        for set in displayedCaptureSets {
            let memberIDs = set.members.map(\.id)
            for id in memberIDs { map[id] = memberIDs }
        }
        return map
    }

    /// Handles a click on a capture-set tile in the source grid: shift-click ranges from the last
    /// anchor, cmd-click toggles the tile in/out of the multi-selection, a plain click resets to a
    /// single selection. Mirrors the reference Python app's `SourcePanel._on_tile_clicked`. Used the
    /// same way regardless of `sourceViewFilter` — previewing/multi-selecting a skipped item never
    /// un-skips it; only `SourcePanelView`'s "Un-skip" context-menu action does that.
    func selectTile(_ id: PhotoAsset.ID, modifiers: NSEvent.ModifierFlags) {
        let visibleIDs = displayedCaptureSets.compactMap { $0.representative?.id }
        if modifiers.contains(.shift), let anchor = rangeAnchorID {
            multiSelectedIDs = SelectionScope.rangeBetween(anchor: anchor, target: id, visible: visibleIDs)
        } else if modifiers.contains(.command) {
            if multiSelectedIDs.contains(id) {
                multiSelectedIDs.remove(id)
            } else {
                multiSelectedIDs.insert(id)
            }
            rangeAnchorID = id
        } else {
            multiSelectedIDs = [id]
            rangeAnchorID = id
        }
        selectedAssetID = id
        refreshVariantStrip()
    }

    /// Recomputes the filmstrip's member list and resets its ring-selection to the full scope.
    /// Called after any change to the grid selection.
    private func refreshVariantStrip() {
        guard let selectedAssetID else {
            variantMemberIDs = []
            variantSelectedIDs = []
            return
        }
        let visibleIDs = displayedCaptureSets.compactMap { $0.representative?.id }
        let orderedMultiSelection = visibleIDs.filter { multiSelectedIDs.contains($0) }
        let scope = SelectionScope.resolveScope(
            selected: selectedAssetID, multiSelected: orderedMultiSelection, membersByID: membersByAssetID)
        variantMemberIDs = scope
        variantSelectedIDs = Set(scope)
    }

    /// Cmd-click on a filmstrip tile: toggles it out of the ring-selection, refusing to drop below
    /// one selected member so the strip is never fully empty (mirrors the reference app).
    func toggleVariantSelection(_ id: PhotoAsset.ID) {
        if variantSelectedIDs.contains(id) {
            guard variantSelectedIDs.count > 1 else { return }
            variantSelectedIDs.remove(id)
        } else {
            variantSelectedIDs.insert(id)
        }
    }

    /// Plain click on a filmstrip tile: switches the large preview to that specific member without
    /// touching the grid multi-selection or the ring-selection.
    func setActivePreview(_ id: PhotoAsset.ID) {
        selectedAssetID = id
    }

    /// Whether the filmstrip's ring-selection has been narrowed away from the full scope it
    /// started at — i.e. the user cmd-clicked at least one member out, but not all the way down to
    /// zero (which `toggleVariantSelection` already disallows).
    var hasPartialVariantSelection: Bool {
        !variantSelectedIDs.isEmpty && variantSelectedIDs.count < variantMemberIDs.count
    }

    /// True when there's a "current selection" distinct from the default single set/asset — either
    /// the grid's manual multi-selection (2+ tiles) or the filmstrip narrowed to a subset of the
    /// active selection's members. Drives whether "Current Selection" is actionable.
    var hasCurrentSelection: Bool { hasMultiSelection || hasPartialVariantSelection }

    /// Assets for a "Current Selection" process/move action (docs/SPEC.md §5's `.manualSelection`
    /// scope). Prefers the filmstrip's narrowed ring-selection when the user has hand-picked a
    /// subset there (e.g. excluded the RAW file from a set they're processing) — the reference
    /// app's variant strip only ever fed a "Save Selected" metadata action, but this app's filmstrip
    /// is also meant to scope process/move. Falls back to the grid's manual multi-selection,
    /// expanded to full capture-group membership, when the filmstrip hasn't been narrowed.
    var manualSelectionAssets: [PhotoAsset] {
        let assetByID = Dictionary(uniqueKeysWithValues: displayedCaptureSets.flatMap(\.members).map { ($0.id, $0) })
        if hasPartialVariantSelection {
            return variantMemberIDs.filter { variantSelectedIDs.contains($0) }.compactMap { assetByID[$0] }
        }
        guard hasMultiSelection else { return [] }
        let visibleIDs = displayedCaptureSets.compactMap { $0.representative?.id }
        let ordered = visibleIDs.filter { multiSelectedIDs.contains($0) }
        let expandedIDs = SelectionScope.expandToCaptureGroups(ordered, membersByID: membersByAssetID)
        return expandedIDs.compactMap { assetByID[$0] }
    }

    private func skippedAssetPaths(inFolder folderURL: URL) async -> Set<String> {
        guard let store = await ensureSkipStore() else { return [] }
        return (try? await store.skippedAssetPaths(inFolder: folderURL.path)) ?? []
    }

    /// Lazily created for the same reason as `skipStore` above.
    private var mergeStore: CaptureSetMergeStore?

    private func ensureMergeStore() async -> CaptureSetMergeStore? {
        if let mergeStore { return mergeStore }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "capture_set_merges.sqlite3")
            let store = try CaptureSetMergeStore(databasePath: databasePath)
            mergeStore = store
            return store
        } catch {
            loadErrorMessage = error.localizedDescription
            return nil
        }
    }

    private func mergeIDs(inFolder folderURL: URL) async -> [String: String] {
        guard let store = await ensureMergeStore() else { return [:] }
        return (try? await store.mergeIDsByAssetPath(inFolder: folderURL.path)) ?? [:]
    }

    private func ensureSkipStore() async -> SkipStateStore? {
        if let skipStore { return skipStore }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "skip_state.sqlite3")
            let store = try SkipStateStore(databasePath: databasePath)
            skipStore = store
            return store
        } catch {
            loadErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Paths (within the currently loaded folder) that have already been through Process & Move at
    /// least once — drives the non-blocking checkmark badge on `CaptureTileView`/`VariantTileView`.
    /// Purely informational: unlike `skippedCaptureSets`, being in this set never hides or disables
    /// anything, since reprocessing must stay freely available.
    @Published private(set) var processedAssetPaths: Set<String> = []

    /// Lazily created for the same reason as `skipStore` above.
    private var processedStore: ProcessedStateStore?

    private func ensureProcessedStore() async -> ProcessedStateStore? {
        if let processedStore { return processedStore }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "processed_state.sqlite3")
            let store = try ProcessedStateStore(databasePath: databasePath)
            processedStore = store
            return store
        } catch {
            return nil
        }
    }

    private func loadProcessedAssetPaths(inFolder folderURL: URL) async -> Set<String> {
        guard let store = await ensureProcessedStore() else { return [] }
        return (try? await store.processedAssetPaths(inFolder: folderURL.path)) ?? []
    }

    /// Persists `assetPaths` as processed for `folderPath` and updates the in-memory set so the
    /// badge appears immediately, without waiting for the next folder load.
    private func markAssetsProcessed(_ assetPaths: [String], inFolder folderPath: String) async {
        guard let store = await ensureProcessedStore() else { return }
        try? await store.markProcessed(assetPaths: assetPaths, inFolder: folderPath)
        processedAssetPaths.formUnion(assetPaths)
    }

    /// Whether `asset` has already been through Process & Move at least once in this folder.
    func isProcessed(_ asset: PhotoAsset) -> Bool {
        processedAssetPaths.contains(asset.url.path)
    }

    /// Whether any member of `captureSet` has already been through Process & Move — a set is shown
    /// as processed as soon as one member has, since the common case processes the whole set at once.
    func isProcessed(_ captureSet: CaptureSet) -> Bool {
        captureSet.members.contains { processedAssetPaths.contains($0.url.path) }
    }

    /// Lazily created for the same reason as `skipStore` above — `TimelineLocationCache.init` is
    /// throwing filesystem/database work, so it can't happen synchronously in `init()`.
    private var timelineCache: TimelineLocationCache?

    private func ensureTimelineCache() async -> TimelineLocationCache? {
        if let timelineCache { return timelineCache }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "timeline_location.sqlite3")
            let cache = try TimelineLocationCache(databasePath: databasePath)
            timelineCache = cache
            return cache
        } catch {
            return nil
        }
    }

    private var elevationCache: ElevationCache?

    private func ensureElevationCache() async -> ElevationCache? {
        if let elevationCache { return elevationCache }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "elevation_cache.sqlite3")
            let cache = try ElevationCache(databasePath: databasePath)
            elevationCache = cache
            return cache
        } catch {
            return nil
        }
    }

    private var ebirdCache: EBirdCache?

    private func ensureEBirdCache() async -> EBirdCache? {
        if let ebirdCache { return ebirdCache }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "ebird_cache.sqlite3")
            let cache = try EBirdCache(databasePath: databasePath)
            ebirdCache = cache
            return cache
        } catch {
            return nil
        }
    }

    private enum TimelineSyncOutcome {
        case imported(sampleCount: Int)
        case upToDate
        case sourceNotFound
        case failed
    }

    /// Copies down a fresher `Timeline.json` from Google Drive (if present) and imports it into
    /// `timelineCache` when its (path, size, mtime) signature has changed — see docs/SPEC.md §7 and
    /// `TimelineLocationCache.isImportNeeded`. Shared by the silent per-launch/per-folder-load sync
    /// (`syncAndImportTimelineIfNeeded()`) and the explicit `refreshTimeline()` button action.
    private func performTimelineSync() async -> TimelineSyncOutcome {
        guard let localCopyPath = try? TimelineDriveSync.resolveLocalCopyPath() else { return .failed }
        if let driveSourcePath = TimelineDriveSync.resolveDriveSourcePath() {
            _ = try? TimelineDriveSync.syncIfNewer(driveSource: driveSourcePath, localCopy: localCopyPath)
        }
        guard FileManager.default.fileExists(atPath: localCopyPath.path) else { return .sourceNotFound }
        guard let cache = await ensureTimelineCache() else { return .failed }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: localCopyPath.path)
            let size = (attributes[.size] as? Int) ?? 0
            let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
            let modificationNanoseconds = Int64(modificationDate.timeIntervalSince1970 * 1_000_000_000)

            guard
                try await cache.isImportNeeded(
                    sourcePath: localCopyPath.path, sourceSize: size,
                    sourceModificationNanoseconds: modificationNanoseconds)
            else { return .upToDate }

            let samples = try timelineImportParser.parseSamples(fromFileAt: localCopyPath)
            let sha256 = try FileHashing.sha256(of: localCopyPath)
            try await cache.importSamples(
                samples, sourcePath: localCopyPath.path, sourceSize: size,
                sourceModificationNanoseconds: modificationNanoseconds, sourceSHA256: sha256)
            return .imported(sampleCount: samples.count)
        } catch {
            return .failed
        }
    }

    /// Silent best-effort Timeline sync/import called from `init` and from every `load(_:)` (i.e.
    /// on folder open/navigate), so replacing `Timeline.json` on Drive mid-session doesn't require
    /// an app relaunch to be picked up. Failure just means GPS suggestions stay unavailable, not a
    /// user-facing error — see `TimelineDriveSync`'s doc comment.
    private func syncAndImportTimelineIfNeeded() async {
        _ = await performTimelineSync()
    }

    /// Explicit "Refresh Timeline" button action — runs the same sync/import as
    /// `syncAndImportTimelineIfNeeded()` but reports the outcome via `timelineSyncStatusMessage`
    /// instead of staying silent, since a user pressing a button expects to see what happened.
    func refreshTimeline() async {
        isSyncingTimeline = true
        defer { isSyncingTimeline = false }
        switch await performTimelineSync() {
        case .imported(let sampleCount):
            timelineSyncStatusMessage = "Imported \(sampleCount) Timeline point(s)."
        case .upToDate:
            timelineSyncStatusMessage = "Timeline is already up to date."
        case .sourceNotFound:
            timelineSyncStatusMessage = "No Timeline.json found."
        case .failed:
            timelineSyncStatusMessage = "Timeline refresh failed."
        }
    }

    /// Timeline-derived GPS suggestion for `selectedAsset`, auto-applied on first focus of a
    /// GPS-less photo — mirrors the reference app's UX (see docs/SPEC.md §7 and
    /// `loadArtFilterTokenIfNeeded()`'s doc comment for the same lazy-per-selection shape). No-ops
    /// whenever the asset already has embedded GPS or the edit buffer already holds something (a
    /// prior suggestion or an in-progress user edit), so this never overwrites real data. Chains an
    /// elevation lookup after a successful match, since altitude is never trusted from Timeline
    /// itself (SPEC.md §7).
    func suggestGPSIfNeeded() async {
        guard let id = selectedAssetID, let asset = selectedAsset,
            asset.gpsLatitude == nil, asset.gpsLongitude == nil,
            editableLatitudeText.isEmpty, editableLongitudeText.isEmpty,
            let capturedAt = asset.capturedAt
        else { return }
        guard let cache = await ensureTimelineCache() else { return }

        let captureTimestampUTC = Int(capturedAt.timeIntervalSince1970)
        guard let suggestion = try? await cache.suggestion(forCaptureTimestampUTC: captureTimestampUTC),
            selectedAssetID == id
        else { return }

        editableLatitudeText = String(suggestion.latitude)
        editableLongitudeText = String(suggestion.longitude)
        let accuracyText = suggestion.accuracyMeters.map { String(format: ", accuracy %.0fm", $0) } ?? ""
        gpsSuggestionStatusMessage =
            "Nearest GPS \(suggestion.ageSeconds / 60)m \(suggestion.ageSeconds % 60)s away "
            + "(\(suggestion.sourceType)\(accuracyText))"

        await lookupElevation(for: id, latitude: suggestion.latitude, longitude: suggestion.longitude)
    }

    private func lookupElevation(for id: PhotoAsset.ID, latitude: Double, longitude: Double) async {
        guard let elevationCache = await ensureElevationCache() else { return }

        if let cached = try? await elevationCache.cachedElevation(latitude: latitude, longitude: longitude) {
            guard selectedAssetID == id else { return }
            updateAsset(id) { $0.gpsAltitude = cached }
            return
        }

        guard let elevation = try? await elevationService.lookupElevation(latitude: latitude, longitude: longitude)
        else { return }
        try? await elevationCache.store(latitude: latitude, longitude: longitude, elevationMeters: elevation)

        guard selectedAssetID == id else { return }
        updateAsset(id) { $0.gpsAltitude = elevation }
    }

    /// Manually re-runs the elevation lookup for the current lat/long — surfaced as a small refresh
    /// button next to the Altitude field for the rare case the automatic USGS EPQS call times out
    /// (mirrors the reference app's manual "lookup altitude" button, `gps_coordinator.py`'s
    /// `_start_altitude_lookup`). No-ops while a lookup is already in flight or lat/long is blank.
    func refreshAltitude() async {
        guard !isLookingUpAltitude, let id = selectedAssetID,
            let latitude = Double(editableLatitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let longitude = Double(editableLongitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }

        isLookingUpAltitude = true
        defer { isLookingUpAltitude = false }
        await lookupElevation(for: id, latitude: latitude, longitude: longitude)
    }

    /// Reverse-geocodes the selected asset's GPS (embedded or freshly Timeline-suggested) into
    /// city/county/state, merges those into the keyword edit buffer, and keeps the result around
    /// keyed by capture-set representative so `suggestAI()` can pass it to the model as location
    /// context — docs/SPEC.md §6/§7, mirrors the reference app's `_start_reverse_geocode`/
    /// `_on_reverse_geocoded`. No-ops without GPS in the edit buffer, and only looks up once per
    /// capture set per session so re-selecting the same set doesn't re-hit the network. Meant to run
    /// after `suggestGPSIfNeeded()` in the same `.task(id:)` chain, so embedded GPS (already in the
    /// buffer from `loadEditBuffer`) and Timeline-suggested GPS (just written by that call) are both
    /// covered by one guard.
    func lookupLocationKeywordsIfNeeded() async {
        guard let id = selectedAssetID,
            let latitude = Double(editableLatitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let longitude = Double(editableLongitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let representativeID = selectedCaptureSet?.representative?.id,
            !geocodeAppliedRepresentativeIDs.contains(representativeID)
        else { return }
        geocodeAppliedRepresentativeIDs.insert(representativeID)

        guard
            let result = try? await reverseGeocodeService.lookupLocation(
                latitude: latitude, longitude: longitude)
        else { return }
        locationContextByRepresentativeID[representativeID] = result.contextText
        await lookupBirdCandidates(
            representativeID: representativeID, county: result.county,
            stateRegionCode: result.stateRegionCode)

        let tokens = result.keywordTokens
        locationKeywordsByRepresentativeID[representativeID] = tokens
        guard !tokens.isEmpty, selectedAssetID == id else { return }
        var keywords = MetadataEditParsing.parseKeywords(editableKeywords)
        var seenLowercased = Set(keywords.map { $0.lowercased() })
        for token in tokens where seenLowercased.insert(token.lowercased()).inserted {
            keywords.append(token)
        }
        editableKeywords = keywords.joined(separator: ", ")
        gpsSuggestionStatusMessage = "Added location keywords: \(tokens.joined(separator: ", "))"
    }

    /// The same location context and eBird candidate list for a capture set nobody has selected —
    /// what `lookupLocationKeywordsIfNeeded()` does for the selected one, minus the edit buffer.
    /// GPS comes off the representative's own metadata rather than the buffer, so a Timeline
    /// suggestion the user has not accepted is deliberately not used here: a batch run writes files
    /// with nobody watching, and a guessed location must not become a written one.
    ///
    /// Returns the location keywords for the caller to fold into what it writes, since without a
    /// buffer to pass through they would otherwise be dropped from a batch-written file.
    @discardableResult
    private func ensureAIContext(for captureSet: CaptureSet) async -> [String] {
        guard let representative = captureSet.representative else { return [] }
        let representativeID = representative.id
        guard !geocodeAppliedRepresentativeIDs.contains(representativeID) else {
            return locationKeywordsByRepresentativeID[representativeID] ?? []
        }
        guard let latitude = representative.gpsLatitude, let longitude = representative.gpsLongitude
        else { return [] }
        geocodeAppliedRepresentativeIDs.insert(representativeID)

        guard
            let result = try? await reverseGeocodeService.lookupLocation(
                latitude: latitude, longitude: longitude)
        else { return [] }
        locationContextByRepresentativeID[representativeID] = result.contextText
        locationKeywordsByRepresentativeID[representativeID] = result.keywordTokens
        await lookupBirdCandidates(
            representativeID: representativeID, county: result.county,
            stateRegionCode: result.stateRegionCode)
        return result.keywordTokens
    }

    private static let birdRegionSpeciesMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let birdTaxonomyMaxAge: TimeInterval = 90 * 24 * 60 * 60
    /// Safety valve against prompt-token growth for the noisy state-level fallback case (a raw state
    /// species list can exceed 1,000 codes) — see `EBirdCandidateFormatting.buildCandidateList`.
    private static let birdCandidateListLimit = 500

    /// Resolves `county` (falling back to the bare `stateRegionCode` when county resolution fails or
    /// isn't available) to an eBird region code, fetches/caches that region's species list and the
    /// global taxonomy, and stores the formatted candidate list for `suggestAI()` to pass along.
    /// No-ops without a `stateRegionCode` (Nominatim didn't report one for this coordinate) or if the
    /// eBird cache can't be opened; any other failure here just means the AI prompt goes out without
    /// a candidate list, matching `lookupLocationKeywordsIfNeeded`'s best-effort posture. Every
    /// no-op path logs why — a silent no-op here previously cost a debugging session tracing a
    /// fabricated species name back to a missing `EBIRD_API_KEY` (env var or Keychain, see
    /// `APIKeyStore`).
    private func lookupBirdCandidates(
        representativeID: PhotoAsset.ID, county: String, stateRegionCode: String?
    ) async {
        guard let stateRegionCode else {
            Self.ebirdLogger.log("Bird candidates skipped: no eBird state region code for this location")
            return
        }
        guard APIKeyStore.resolve(envVar: "EBIRD_API_KEY", account: "EBIRD_API_KEY") != nil else {
            Self.ebirdLogger.log("Bird candidates skipped: EBIRD_API_KEY not set (env or Keychain)")
            return
        }
        guard let cache = await ensureEBirdCache() else {
            Self.ebirdLogger.log("Bird candidates skipped: could not open EBirdCache")
            return
        }

        var regionCode = stateRegionCode
        if !county.isEmpty,
            let regions = try? await ebirdService.fetchSubnational2Regions(
                parentCode: stateRegionCode),
            let matched = EBirdCandidateFormatting.matchRegion(countyName: county, in: regions)
        {
            regionCode = matched.code
        } else {
            Self.ebirdLogger.log(
                "Bird candidates: county \(county, privacy: .public) not resolved, falling back to state region \(stateRegionCode, privacy: .public)"
            )
        }

        guard let codes = await birdSpeciesCodes(forRegionCode: regionCode, cache: cache) else {
            Self.ebirdLogger.log(
                "Bird candidates skipped: species-code fetch failed for region=\(regionCode, privacy: .public)"
            )
            return
        }
        guard let taxonomy = await birdTaxonomyEntries(forSpeciesCodes: codes, cache: cache) else {
            Self.ebirdLogger.log("Bird candidates skipped: taxonomy fetch failed")
            return
        }

        let candidateList = EBirdCandidateFormatting.buildCandidateList(
            speciesCodes: codes, taxonomy: taxonomy, limit: Self.birdCandidateListLimit)
        guard !candidateList.isEmpty else {
            Self.ebirdLogger.log(
                "Bird candidates skipped: 0 taxonomy matches for \(codes.count, privacy: .public) species codes in region=\(regionCode, privacy: .public)"
            )
            return
        }
        birdCandidateSpeciesByRepresentativeID[representativeID] = candidateList
        birdScientificNamesByRepresentativeID[representativeID] =
            EBirdCandidateFormatting.scientificNameByCommonName(speciesCodes: codes, taxonomy: taxonomy)
        Self.ebirdLogger.log(
            "Bird candidates: region=\(regionCode, privacy: .public) speciesCodes=\(codes.count, privacy: .public) matched=\(taxonomy.count, privacy: .public)"
        )
    }

    private func birdSpeciesCodes(forRegionCode regionCode: String, cache: EBirdCache) async -> [String]? {
        if let cached = try? await cache.cachedSpeciesCodes(regionCode: regionCode),
            Date().timeIntervalSince(cached.fetchedAt) < Self.birdRegionSpeciesMaxAge
        {
            return cached.codes
        }
        guard let codes = try? await ebirdService.fetchSpeciesCodes(regionCode: regionCode) else {
            return nil
        }
        try? await cache.storeSpeciesCodes(codes, regionCode: regionCode)
        return codes
    }

    private func birdTaxonomyEntries(
        forSpeciesCodes codes: [String], cache: EBirdCache
    ) async -> [EBirdTaxonEntry]? {
        let taxonomyFetchedAt = try? await cache.taxonomyFetchedAt()
        let isFresh = taxonomyFetchedAt.map { Date().timeIntervalSince($0) < Self.birdTaxonomyMaxAge } ?? false
        if !isFresh, let taxonomy = try? await ebirdService.fetchTaxonomy() {
            try? await cache.replaceTaxonomy(taxonomy)
        }
        return try? await cache.taxonomyEntries(forSpeciesCodes: codes)
    }

    /// Cap the frame at 1024px for Foundation Models (same as the iPad) to keep the image's token
    /// cost within that small context window; the other Mac providers keep the full 2048.
    private static func aiPreviewMaxPixelSize(for providerID: AIProviderID) -> Int {
        providerID == .foundation ? 1024 : 2048
    }

    /// One capture set's AI pass, from the prepared image on: prompt context, the provider round
    /// trip, and the eBird binomial enrichment. Shared by `suggestAI()` and `runBatchAISuggestion()`
    /// so a batch-written file is the same answer the user would have got clicking Suggest on that
    /// set. Everything selection-shaped stays with the caller — the manual crop, the typed keyword
    /// hint, the evaluated-image preview, the edit buffer.
    ///
    /// `trustedKeywords` are keywords already believed correct for this photo, which the eBird
    /// enrichment may attach a binomial to. That is the user's own typed hint on the selected set,
    /// and nothing at all in a batch run: there is nobody there to have typed one.
    private func aiSuggestion(
        representativeID: PhotoAsset.ID?, provider: AIProvider, selection: AIModelSelection,
        image: CGImage, existingDescription: String, existingKeywords: String,
        trustedKeywords: [String]
    ) async throws -> (description: String, keywords: [String], result: AISuggestionResult) {
        let locationContext = representativeID.flatMap { locationContextByRepresentativeID[$0] } ?? ""
        // Foundation Models has a small (~4k-token) context window that the image already eats a large
        // share of, so the up-to-500-species eBird candidate list overflows it ("Exceeded model
        // context window size"). Skip the list for that provider: its typed `species` field plus the
        // deterministic `attachScientificNames` lookup already deliver region binomials, and the small
        // location-context line (kept) still biases identification toward local species.
        let birdCandidateSpecies =
            selection.providerID == .foundation || eBirdDisabledModels.contains(aiModelText)
            ? ""
            : representativeID.flatMap { birdCandidateSpeciesByRepresentativeID[$0] } ?? ""
        let promptProfile: PromptProfile = selection.providerID == .foundation ? .guided : .full

        let result = try await aiSuggestionService.suggest(
            provider: provider, model: selection.modelName, image: image,
            existingDescription: existingDescription, existingKeywords: existingKeywords,
            locationContext: locationContext, birdCandidateSpecies: birdCandidateSpecies,
            promptProfile: promptProfile)
        var description = result.description
        var keywords = result.keywords

        if let scientificNames = representativeID.flatMap({ birdScientificNamesByRepresentativeID[$0] }) {
            // Post-hoc-validate a guided provider's typed species guess against the photo's eBird
            // region: `foundation:` is sent no candidate list (it won't fit its context window), so
            // it guesses freely and often names an out-of-region or non-existent species ("American
            // Goldeneye"). Trust it only when it's a real species in the region; a failed lookup
            // yields "", so `attachScientificNames` still enriches any region species named in the
            // description/trusted keywords, but the bogus typed guess is neither binomial-attached
            // nor added as a keyword.
            let validatedSpecies =
                EBirdCandidateFormatting.regionalScientificName(
                    forSpecies: result.species, scientificNameByCommonName: scientificNames) != nil
                ? result.species : ""
            let enriched = EBirdCandidateFormatting.attachScientificNames(
                description: description, keywords: keywords, trustedKeywords: trustedKeywords,
                species: validatedSpecies, scientificNameByCommonName: scientificNames)
            description = enriched.description
            keywords = enriched.keywords
            if !validatedSpecies.isEmpty,
                !keywords.contains(where: { $0.caseInsensitiveCompare(validatedSpecies) == .orderedSame })
            {
                keywords.insert(validatedSpecies, at: 0)
            }
        }
        return (description, keywords, result)
    }

    /// Sends the AI-source representative image (docs/SPEC.md §6: prefer RAW over a heavily
    /// in-camera-filtered JPEG) to whichever provider `aiModelText` selects (see
    /// `AIModelSelection`) and fills the description/keywords fields with its response, then
    /// auto-saves immediately — matching the Python reference app's behavior exactly, per user
    /// direction (there is no separate accept/apply step). When
    /// the grid has a multi-capture-set selection active, the suggestion is applied and saved to
    /// every member of every selected set, but the image sent to the model is always drawn from
    /// the *first* selected set (grid order) — picking a dissimilar mix of sets to suggest across
    /// is the user's own responsibility, not something this method tries to detect.
    ///
    /// Call `startAISuggestion()` from the UI rather than this directly — it wraps this in the
    /// cancellable `Task` `cancelAISuggestion()` needs.
    func suggestAI() async {
        guard !isSuggestingAI, let id = selectedAssetID else { return }
        guard let selection = AIModelSelection.parse(aiModelText) else {
            aiStatusMessage =
                "Invalid AI model — expected \"ollama:<model>\", \"openrouter:<model>\", \"mlx:<model>\", or \"foundation:apple\""
            return
        }
        let provider: AIProvider
        switch selection.providerID {
        case .ollama: provider = ollamaProvider
        case .openRouter: provider = openRouterProvider
        case .mlx: provider = mlxProvider
        case .foundation: provider = foundationProvider
        }

        let targetAssets: [PhotoAsset]
        let sourceSetMembers: [PhotoAsset]
        let sourceRepresentativeID: PhotoAsset.ID?
        if hasMultiSelection {
            targetAssets = manualSelectionAssets
            guard
                let firstSelectedSet = captureSets.first(where: {
                    guard let representativeID = $0.representative?.id else { return false }
                    return multiSelectedIDs.contains(representativeID)
                })
            else { return }
            sourceSetMembers = firstSelectedSet.members
            sourceRepresentativeID = firstSelectedSet.representative?.id
        } else {
            guard let captureSet = selectedCaptureSet else { return }
            targetAssets = captureSet.members
            sourceSetMembers = captureSet.members
            sourceRepresentativeID = captureSet.representative?.id
        }
        guard !targetAssets.isEmpty,
            let sourceAsset = AISuggestionSourcePicker.pickSourceAsset(from: sourceSetMembers)
        else { return }
        isSuggestingAI = true
        aiStatusMessage = "Generating AI suggestions…"
        defer { isSuggestingAI = false }
        do {
            let cgImage = try await NativeMetadataReader().extractPreviewAsync(
                at: sourceAsset.url, maxPixelSize: Self.aiPreviewMaxPixelSize(for: selection.providerID))
            let subjectCrop: CGImage?
            if !subjectIsolationEnabled {
                subjectCrop = nil
            } else if let manualRect = manualSubjectCropRect {
                // Applied to whatever file is actually sent below (`sourceAsset`), even if it was
                // drawn against a different member of the capture set (e.g. the previewed JPEG of a
                // RAW+JPEG pair) — the user's call; RAW and JPEG share framing for virtually every
                // camera, and `cropping(to:)` fails safe to `nil` (full frame) on an out-of-bounds rect.
                subjectCrop = cgImage.cropping(to: manualRect)
            } else {
                subjectCrop = await computeSubjectCrop(in: cgImage)
            }
            let evaluatedImage = subjectCrop ?? cgImage
            guard selectedAssetID == id else { return }
            aiEvaluatedImage = evaluatedImage
            aiEvaluatedImageSourceName = sourceAsset.url.lastPathComponent
            // Foundation Models uses `@Generable` guided generation, so it takes the `.guided` prompt
            // (no "return JSON" framing, typed species field); every other Mac provider takes `.full`.
            // Captured before `editableKeywords` is overwritten below: the model's list replaces the
            // whole field, and a keyword the user typed as a hint has to survive that whether or not
            // the model chose to echo it back.
            let userAddedKeywords = MetadataEditParsing.userAddedKeywords(
                current: MetadataEditParsing.parseKeywords(editableKeywords), loaded: loadedKeywords)
            let (description, keywords, result) = try await aiSuggestion(
                representativeID: sourceRepresentativeID, provider: provider, selection: selection,
                image: evaluatedImage, existingDescription: editableDescription,
                existingKeywords: editableKeywords,
                trustedKeywords: MetadataEditParsing.parseKeywords(editableKeywords))
            guard selectedAssetID == id else { return }
            editableDescription = description
            editableKeywords = MetadataEditParsing.merging(userAdded: userAddedKeywords, into: keywords)
                .joined(separator: ", ")
            // The timeout-retry crop (`AISuggestionService`'s separate fallback, unrelated to the
            // subject-isolation toggle) narrows the frame again, so the retry's own image is what
            // actually produced this result.
            if result.timeoutRetrySucceeded {
                aiEvaluatedImage = result.evaluatedImage
            }
            let categorySuffix = result.sceneCategory == .other ? "" : " [\(result.sceneCategory.rawValue)]"
            aiStatusMessage =
                (result.timeoutRetrySucceeded ? "Suggested (after retry)" : "Suggested")
                + categorySuffix + sentFromSuffix(sourceAsset: sourceAsset) + "; saving…"
            let saveStatus = await performSave(scope: .manualSelection(targetAssets))
            guard selectedAssetID == id else { return }
            if let saveStatus {
                aiStatusMessage =
                    "Suggested\(categorySuffix)\(sentFromSuffix(sourceAsset: sourceAsset)); \(saveStatus)"
            }
        } catch is CancellationError {
            guard selectedAssetID == id else { return }
            aiStatusMessage = "AI suggestion cancelled"
        } catch {
            guard selectedAssetID == id else { return }
            aiStatusMessage = "AI suggestion failed: \(error.localizedDescription)"
        }
    }

    /// `" · from <file>"` when the asset sent to the AI isn't the one the big preview is showing —
    /// `AISuggestionSourcePicker` prefers the capture set's RAW while `selectedAsset` is its
    /// JPEG-first representative, so on a RAW+JPEG set the model and the user look at different
    /// files. Empty when they agree, to keep the common single-file case's status line short.
    private func sentFromSuffix(sourceAsset: PhotoAsset) -> String {
        guard sourceAsset.id != selectedAssetID else { return "" }
        return " · from \(sourceAsset.url.lastPathComponent)"
    }

    /// Starts `suggestAI()` as a cancellable `Task`, stashing the handle for `cancelAISuggestion()`.
    /// The UI (`MetadataPanelView`'s "Suggest" button) calls this instead of running `suggestAI()`
    /// directly.
    func startAISuggestion() {
        suggestAITask = Task { await suggestAI() }
    }

    /// The "break key" for a stuck local MLX generation (docs/MLX_PROVIDER.md "No request-level
    /// timeout") — cancels the in-flight `suggestAI()` `Task`, which `MLXNativeProvider.chat`
    /// observes cooperatively and unwinds from cleanly rather than waiting for a result that may
    /// never come. `isSuggestingAI`'s existing `defer` in `suggestAI()` still resets it once the
    /// cancelled task actually finishes unwinding, so the Suggest button re-enables promptly rather
    /// than needing a second signal.
    func cancelAISuggestion() {
        suggestAITask?.cancel()
    }

    var selectedAsset: PhotoAsset? {
        displayedCaptureSets
            .flatMap(\.members)
            .first { $0.id == selectedAssetID }
    }

    /// The capture set the selected tile belongs to. Matches on full membership rather than just
    /// `representative` because `setActivePreview` (a filmstrip click) can point `selectedAssetID`
    /// at a non-representative member, e.g. the RAW file behind a stacked JPEG representative.
    var selectedCaptureSet: CaptureSet? {
        displayedCaptureSets.first { set in set.members.contains { $0.id == selectedAssetID } }
    }

    /// Keyboard-shortcut entry point for skipping the current selection — see `SourcePanelView`'s
    /// delete-key binding, which is disabled while browsing the Skipped filter so this can't be
    /// invoked on a set that's already skipped. No-op with nothing selected.
    func skipSelected() {
        guard let selectedCaptureSet else { return }
        skip(selectedCaptureSet)
    }

    @Published private(set) var isDevelopingRAW = false
    @Published var developStatusMessage: String?

    /// Whether Develop RAW has anything to do for `scope` — drives the context menu item's enabled
    /// state, so it must stay cheap enough to evaluate during a view update. It answers from the
    /// loaded capture sets rather than the filesystem: derivatives are merged in by `load(_:)`, so
    /// "already developed" is just "some member points back at this RAW".
    func canDevelopRAW(scope: ProcessMoveScope) -> Bool {
        rawDerivedStore != nil && !rawAssetsNeedingDevelop(in: scope).isEmpty
    }

    private func rawAssetsNeedingDevelop(in scope: ProcessMoveScope) -> [PhotoAsset] {
        let alreadyDeveloped = Set(captureSets.flatMap(\.members).compactMap(\.derivedFrom))
        return scope.assets.filter {
            PhotoAssetLoader.isRaw($0.url) && !alreadyDeveloped.contains($0.url)
        }
    }

    /// Trashes staged RAW derivatives that have already been copied into the library, so app storage
    /// doesn't keep a second copy of every developed frame.
    ///
    /// Deliberately not done at process time. The reload that follows a process would then find the
    /// derivative's file gone (`RawDerivedStore.derivedAssets(forOriginals:)` only returns ones that
    /// still exist) and drop its tile out of the grid and filmstrip, so the frame the user just
    /// rendered would disappear rather than show its processed check mark. Instead the derivative
    /// lives for as long as its folder stays open, and goes when the user navigates away.
    ///
    /// The second pass is what makes that safe across a quit: `keptDerivativeOriginals` is in-memory
    /// only, so a session that ends while some are still held would otherwise strand them. Any
    /// derivative whose own staging path is already recorded processed has served its purpose and is
    /// swept on the next load of its folder.
    ///
    /// Nothing is lost either way — a discarded derivative is a couple of seconds of re-develop away
    /// from the RAW that is still sitting in the folder.
    private func discardSpentDerivatives(
        for assets: [PhotoAsset], inFolder folderURL: URL, processedPaths: Set<String>
    ) {
        guard let store = rawDerivedStore else { return }

        // A derivative is "spent" once its own staging path is recorded processed — that path is
        // what `process(scope:libraryRoot:)` wrote to `ProcessedStateStore`, under this folder.
        let spent = Set(
            assets.lazy
                .filter { PhotoAssetLoader.isRaw($0.url) }
                .filter { asset in
                    guard let derivedURL = try? store.derivedURL(for: asset.url) else { return false }
                    return processedPaths.contains(derivedURL.path)
                }
                .map(\.url))

        let decision = Self.derivativeSweep(
            loadingFolderPath: folderURL.path,
            keptFolderPath: keptDerivativeFolderPath,
            keptOriginals: keptDerivativeOriginals,
            spentOriginalsInFolder: spent)

        for original in decision.discard {
            try? store.discard(for: original)
        }
        keptDerivativeOriginals = decision.stillKept
        keptDerivativeFolderPath = decision.stillKept.isEmpty ? nil : keptDerivativeFolderPath
    }

    /// The rule behind `discardSpentDerivatives`, split out so it can be tested without a staging
    /// directory or a live folder: staying in the folder holds its derivatives, leaving it releases
    /// them, and anything already spent that nobody is holding goes regardless (the leftovers of a
    /// session that quit mid-hold).
    static func derivativeSweep(
        loadingFolderPath: String,
        keptFolderPath: String?,
        keptOriginals: Set<URL>,
        spentOriginalsInFolder: Set<URL>
    ) -> (discard: Set<URL>, stillKept: Set<URL>) {
        let stillKept = keptFolderPath == loadingFolderPath ? keptOriginals : []
        return (spentOriginalsInFolder.union(keptOriginals).subtracting(stillKept), stillKept)
    }

    /// Renders every not-yet-developed RAW file in `scope` to a JPEG in `RawDerivedStore`, then
    /// reloads so the results appear as members of their originals' capture sets. See docs/SPEC.md
    /// §5 "RAW develop" and `RawDevelopService` for how the decoder is chosen.
    ///
    /// The decoder token is written into the derivative's own IPTC keywords rather than held in
    /// memory. A staged derivative outlives the session that made it, and the token has to survive
    /// with it: it is what puts `RAW9` in the processed filename, and recomputing it later would
    /// mean decoding the RAW again just to ask which decoder ran.
    ///
    /// One file's failure doesn't stop the rest, same as `process(scope:libraryRoot:)`.
    func developRAW(scope: ProcessMoveScope) {
        guard !isDevelopingRAW, let store = rawDerivedStore else { return }
        let targets = rawAssetsNeedingDevelop(in: scope)
        guard !targets.isEmpty else { return }
        let folderURL = breadcrumb.last

        isDevelopingRAW = true
        developStatusMessage = "Developing \(targets.count) RAW file(s)…"
        Task {
            defer { isDevelopingRAW = false }
            // Absent DNG Converter is not an error: `RawDevelopService` falls back to the newest
            // decoder the file itself offers, and the token reports whichever one that was.
            let service = RawDevelopService(dngConverter: AdobeDNGConverter())
            var failures: [String] = []

            for (index, target) in targets.enumerated() {
                developStatusMessage =
                    "Developing \(index + 1) of \(targets.count): \(target.url.lastPathComponent)…"
                do {
                    let destination = try store.derivedURL(for: target.url)
                    let result = try await service.develop(target.url, to: destination)
                    try await exifTool.write(
                        title: nil, description: "", keywords: [result.token], gps: nil,
                        to: destination)
                } catch {
                    failures.append("\(target.url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if let folderURL {
                load(folderURL, preservingSelection: true)
            }
            let successCount = targets.count - failures.count
            developStatusMessage =
                failures.isEmpty
                ? "Developed \(successCount) RAW file(s)."
                : "Developed \(successCount)/\(targets.count); \(failures.count) failed:\n"
                    + failures.joined(separator: "\n")
        }
    }

    /// Resolves `scope` to its concrete assets (see `ProcessMoveScope.assets`) and copies each into
    /// `libraryRoot` via `ProcessMoveService`, per docs/SPEC.md §5. One asset's failure (a bad copy,
    /// a metadata-write error) doesn't stop the rest of the scope from processing — failures are
    /// collected and surfaced together afterward, the same "don't let one bad file fail the whole
    /// batch" approach `ExifToolClient` uses. Reports progress/outcome via `processStatusMessage`
    /// rather than `loadErrorMessage`, since that property's View treatment replaces the whole
    /// thumbnail grid — appropriate for a folder-load failure, wrong for a process action that
    /// should leave the grid exactly as it was.
    ///
    /// No-op while a previous call is still running, and no-op on an empty scope (nothing
    /// selected). Auto-skip-on-success (SPEC.md §5: "successfully processed files auto-skip from
    /// the current session view") isn't wired yet — this only performs the copy-and-write-metadata
    /// step.
    func process(scope: ProcessMoveScope, libraryRoot: URL) {
        guard !isProcessing else { return }
        let assets = scope.assets
        guard !assets.isEmpty else { return }
        // Captured now, not read from `breadcrumb.last` after the `Task` finishes — mirrors
        // `skip(_:)`'s reasoning: the user could navigate to a different folder while this is
        // still running.
        let folderPath = breadcrumb.last?.path

        isProcessing = true
        processedFileCount = 0
        processTotalCount = assets.count
        // The art-filter read is one batched exiftool call ahead of the per-file loop, so it gets
        // its own message rather than sitting at "1 of N" while nothing is being copied yet.
        processStatusMessage = "Reading metadata for \(assets.count) file(s)…"
        Task {
            defer { isProcessing = false }
            await loadArtFilterTokens(for: assets)
            let assetByID = Dictionary(
                uniqueKeysWithValues: captureSets.flatMap(\.members).map { ($0.id, $0) })
            var failures: [String] = []
            var processedPaths: [String] = []
            var developedOriginals: [URL] = []
            for asset in assets {
                let asset = assetByID[asset.id] ?? asset
                processStatusMessage =
                    "Processing \(processedFileCount + 1) of \(assets.count): \(asset.url.lastPathComponent)"
                let context = Self.renameContext(for: asset, batch: sessionBatch)
                do {
                    _ = try await processMoveService.processAndCopy(
                        asset: asset, renameContext: context, libraryRoot: libraryRoot)
                    processedPaths.append(asset.url.path)
                    if let original = asset.derivedFrom {
                        developedOriginals.append(original)
                    }
                } catch {
                    failures.append("\(asset.url.lastPathComponent): \(error.localizedDescription)")
                }
                processedFileCount += 1
            }
            // The derivative existed only to reach the library, but trashing it here would delete
            // it out from under the reload below, and the tile would vanish from the grid and the
            // filmstrip instead of gaining its processed check mark — on the one frame the user
            // just rendered and most wants confirmation for. Held until the folder is left, then
            // swept by `discardSpentDerivatives(for:inFolder:processedPaths:)`.
            if !developedOriginals.isEmpty {
                keptDerivativeOriginals.formUnion(developedOriginals)
                keptDerivativeFolderPath = folderPath
            }
            if let folderPath, !processedPaths.isEmpty {
                await markAssetsProcessed(processedPaths, inFolder: folderPath)
            }
            // Only after the processed state is recorded, so the reloaded grid shows the badges.
            if !developedOriginals.isEmpty, let folderPath {
                load(URL(fileURLWithPath: folderPath), preservingSelection: true)
            }
            let successCount = assets.count - failures.count
            if failures.isEmpty {
                processStatusMessage = "Processed \(successCount) file(s)."
            } else {
                processStatusMessage =
                    "Processed \(successCount)/\(assets.count) file(s); \(failures.count) failed:\n"
                    + failures.joined(separator: "\n")
            }
        }
    }

    /// Imports a folder of iPad-processed files into `libraryRootURL` via `IPadImportService` — see
    /// that type for what the iPad couldn't finish and why. Unlike `process(scope:libraryRoot:)`
    /// this has nothing to do with the current session: it reads a folder the user pulled off the
    /// iPad, so it touches neither `captureSets` nor the processed-state store.
    ///
    /// No-op while a previous import is running or when no library folder is set.
    func importIPadExport(from exportRoot: URL) {
        guard !isImportingIPadExport, let libraryRoot = libraryRootURL else { return }

        isImportingIPadExport = true
        iPadImportSummary = nil
        iPadImportedFileCount = 0
        iPadImportTotalCount = 0
        iPadImportStatusMessage = "Scanning \(exportRoot.lastPathComponent)…"
        Task {
            defer { isImportingIPadExport = false }
            do {
                let summary = try await IPadImportService().importAll(
                    from: exportRoot, into: libraryRoot,
                    onProgress: { [weak self] completed, total, outcome in
                        Task { @MainActor in
                            self?.iPadImportedFileCount = completed
                            self?.iPadImportTotalCount = total
                            self?.iPadImportStatusMessage = "\(completed) of \(total): \(outcome.sourceName)"
                        }
                    })
                iPadImportSummary = summary
                iPadImportStatusMessage =
                    summary.outcomes.isEmpty
                    ? "No photos found in \(exportRoot.lastPathComponent)."
                    : "Imported \(summary.importedCount) of \(summary.outcomes.count) file(s)."
                        + Self.developSuffix(for: summary)
            } catch {
                iPadImportStatusMessage = error.localizedDescription
            }
        }
    }

    /// Reports the RAW-develop half of an import, which only happens for files the iPad marked. Says
    /// nothing at all when none were marked — the common case.
    private static func developSuffix(for summary: IPadImportSummary) -> String {
        var parts: [String] = []
        if summary.developedCount > 0 { parts.append("Developed \(summary.developedCount) RAW file(s).") }
        if !summary.developFailures.isEmpty {
            parts.append("\(summary.developFailures.count) RAW develop(s) failed.")
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    /// Resets the metadata edit buffer to `selectedAsset`'s current field values (or clears it when
    /// nothing's selected) — called from `selectedAssetID`'s `didSet` so the form always reflects
    /// whichever photo is currently shown large. Also clears `gpsSuggestionStatusMessage`, since
    /// it's a shared status line for both the Timeline-GPS-suggestion and reverse-geocode-keyword
    /// features — without this it would keep showing the previous photo's message (e.g. a geocoded
    /// location) for a newly selected photo that has no GPS at all.
    private func loadEditBuffer() {
        gpsSuggestionStatusMessage = nil
        // The previous photo's subject-crop state never applies to the new one — clear it before
        // possibly recomputing below, same as `editableDescription`/etc. reset for a new asset.
        subjectCropTask?.cancel()
        manualSubjectCropRect = nil
        aiEvaluatedImage = nil
        aiEvaluatedImageSourceName = nil
        aiStatusMessage = nil
        guard let asset = selectedAsset else {
            editableDescription = ""
            editableKeywords = ""
            loadedKeywords = []
            editableLatitudeText = ""
            editableLongitudeText = ""
            updateRenamePreview()
            return
        }
        editableDescription = asset.descriptionText
        editableKeywords = asset.keywords.joined(separator: ", ")
        loadedKeywords = asset.keywords
        editableLatitudeText = asset.gpsLatitude.map { String($0) } ?? ""
        editableLongitudeText = asset.gpsLongitude.map { String($0) } ?? ""
        updateRenamePreview()
        // The toggle being "on" should keep behaving as on across a photo switch, not require
        // re-flipping it — see `setSubjectIsolationEnabled`.
        if subjectIsolationEnabled {
            recomputeSubjectCropPreview()
        }
    }

    /// The rename inputs for `asset`, shared by the preview and the actual process run so the name
    /// shown is the name written.
    ///
    /// A RAW-developed derivative needs both fields redirected. Its own filename is a
    /// `RawDerivedStore` key, and `RenameService.sequence(from:)` harvests every digit in the stem,
    /// so the leading file size would be absorbed into the frame number — the rename is handed a
    /// stand-in built from the original's name instead, the same device `IPadImportService`
    /// documents at `sequenceOnlyURL`. And the decoder token goes in the art-filter *filename* slot
    /// while `asset.artFilterToken` stays empty: an ORF carries no in-camera effect, so the
    /// "In camera effect …" description note (`AutoMetadataRules`) must not fire for it.
    /// Internal rather than private so the derived-asset rules above can be unit tested without
    /// standing up a whole browsing session.
    static func renameContext(for asset: PhotoAsset, batch: String) -> RenameContext {
        guard let original = asset.derivedFrom else {
            return RenameContext(
                sourceURL: asset.url,
                capturedAt: asset.capturedAt,
                cameraModel: asset.cameraModel,
                lensModel: asset.lensModel,
                batch: batch,
                artFilterToken: asset.artFilterToken)
        }
        return RenameContext(
            sourceURL: original.deletingPathExtension().appendingPathExtension(asset.url.pathExtension),
            capturedAt: asset.capturedAt,
            cameraModel: asset.cameraModel,
            lensModel: asset.lensModel,
            batch: batch,
            artFilterToken: RawDevelopService.token(in: asset.keywords))
    }

    /// Recomputes `renamePreviewFilename` for `selectedAsset` against `sessionBatch`'s current
    /// value — see that property's doc comment for why this exists and when it's called.
    private func updateRenamePreview() {
        guard let asset = selectedAsset else {
            renamePreviewFilename = ""
            return
        }
        let candidate = renameService.buildFilename(for: Self.renameContext(for: asset, batch: sessionBatch))

        var existingNames = Self.existingFileNames(in: asset.url.deletingLastPathComponent())
        existingNames.remove(asset.url.lastPathComponent)
        renamePreviewFilename = renameService.ensureUniqueName(candidate, existingNames: existingNames)
    }

    private static func existingFileNames(in directory: URL) -> Set<String> {
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        return Set(names ?? [])
    }

    /// Lazily reads `selectedAsset`'s maker-note fields via `ExifToolClient` and fills in
    /// `artFilterToken`, per docs/SPEC.md §2/§4 — `NativeMetadataReader`'s fast ImageIO-based
    /// initial load can't reach Olympus's proprietary maker-note tags (see its doc comment), so
    /// this fills the gap with one `exiftool` read for whichever asset is actually being looked at.
    /// Meant to be driven by a View's `.task(id: selectedAssetID)`, which cancels any still-in-
    /// flight read for the previous asset on reselection; the `selectedAssetID == id` guard after
    /// the `await` discards a stale result that finishes after the selection has already moved on
    /// (the underlying `exiftool` process isn't itself interruptible by task cancellation). `nil`
    /// on `artFilterToken` means "not yet loaded" — once loaded it's set to `""` rather than left
    /// `nil` even when no art filter was found, so this never re-reads the same file twice. Batch
    /// scopes (capture set / session / manual selection) use `loadArtFilterTokens(for:)` below
    /// instead, since a per-asset read there would be one `exiftool` process launch per file.
    ///
    /// Also corrects `descriptionText` from this same `exiftool` read: real camera-original JPEGs
    /// (confirmed against an actual OM SYSTEM card file, not just synthetic fixtures) have an
    /// ImageIO limitation where `CGImageSourceCopyPropertiesAtIndex`'s IPTC dictionary — and even
    /// `CGImageMetadataCreateFromXMPData`'s `dc:description` — comes back as an empty string for
    /// `Caption-Abstract`/`XMP-dc:Description` despite the on-disk IPTC bytes being correct (verified
    /// by parsing the raw IPTC IIM dataset directly: the `2:120` Caption-Abstract entry is present
    /// with the right value). Byline/copyright/keywords in the same file parse fine via ImageIO, so
    /// this is narrowly a `Caption-Abstract`/description read gap, not a general IPTC failure.
    /// `NativeMetadataReader`'s initial scan (`PhotoAssetLoader`) is the path affected, since it
    /// never shells out to `exiftool`; this only overwrites `editableDescription` if the user
    /// hasn't already started typing into it since selecting this asset.
    func loadArtFilterTokenIfNeeded() async {
        guard let id = selectedAssetID, let asset = selectedAsset, asset.artFilterToken == nil
        else { return }
        let descriptionBeforeFetch = asset.descriptionText
        guard let metadata = try? await exifTool.readMetadata(at: asset.url) else { return }
        guard selectedAssetID == id else { return }
        updateAsset(id) { current in
            current.artFilterToken = ArtFilterTokenParsing.token(from: metadata)
            current.cameraLook = CameraLookParsing.parse(from: metadata)
            current.focusDistance = (metadata["Olympus:FocusDistance"] as? String) ?? ""
            if let correctedDescription = metadata["IPTC:Caption-Abstract"] as? String,
                !correctedDescription.isEmpty, correctedDescription != current.descriptionText {
                current.descriptionText = correctedDescription
            }
        }
        updateRenamePreview()
        if editableDescription == descriptionBeforeFetch {
            editableDescription = selectedAsset?.descriptionText ?? editableDescription
        }
    }

    /// Batch-fills `artFilterToken` for every asset in `assets` that doesn't have one loaded yet,
    /// via `ExifToolClient`'s already-batched multi-file read rather than one `exiftool` launch per
    /// file — called before Process & Move so a full capture-set/session/manual-selection scope
    /// gets an accurate art-filter rename token even for files the user never individually selected
    /// (the only thing that triggers `loadArtFilterTokenIfNeeded` above). Also applies that same
    /// function's `descriptionText` correction (see its doc comment for the ImageIO
    /// `Caption-Abstract` read gap) — without this, an asset the user never selected keeps whatever
    /// empty/wrong description `PhotoAssetLoader`'s ImageIO-only scan produced, and Process & Move
    /// would write just the art-filter note to the destination on top of that empty string, even
    /// though the source file's on-disk description was always correct.
    private func loadArtFilterTokens(for assets: [PhotoAsset]) async {
        let missing = assets.filter { $0.artFilterToken == nil }
        guard !missing.isEmpty else { return }
        let results = (try? await exifTool.readMetadata(at: missing.map(\.url))) ?? [:]
        for asset in missing {
            guard case .success(let metadata) = results[asset.url] else { continue }
            updateAsset(asset.id) { current in
                current.artFilterToken = ArtFilterTokenParsing.token(from: metadata)
                current.cameraLook = CameraLookParsing.parse(from: metadata)
                current.focusDistance = (metadata["Olympus:FocusDistance"] as? String) ?? ""
                if let correctedDescription = metadata["IPTC:Caption-Abstract"] as? String,
                    !correctedDescription.isEmpty, correctedDescription != current.descriptionText {
                    current.descriptionText = correctedDescription
                }
            }
        }
    }

    /// Finds `id` across every capture group and applies `mutate` in place — the one spot that knows
    /// how to reach into the nested `members` arrays, so a successful metadata save can update
    /// in-memory state immediately without re-reading the file back from disk.
    ///
    /// Writes to `automaticCaptureSets` and re-derives, rather than editing the published
    /// `captureSets` directly: that array is a view of the grouping (see `rederiveCaptureSets()`), so
    /// an edit made only there would be thrown away by the next skip, un-skip or merge.
    private func updateAsset(_ id: PhotoAsset.ID, _ mutate: (inout PhotoAsset) -> Void) {
        for setIndex in automaticCaptureSets.indices {
            if let memberIndex = automaticCaptureSets[setIndex].members.firstIndex(where: { $0.id == id }) {
                mutate(&automaticCaptureSets[setIndex].members[memberIndex])
                rederiveCaptureSets()
                return
            }
        }
    }

    /// Saves the current edit buffer to `scope`'s file(s) via `ExifToolClient`, per docs/SPEC.md §3.
    ///
    /// Title is deliberately not part of this action — per the Python reference app, it is never
    /// user-typed at all, only ever written at Process & Move time from the rename candidate's stem
    /// (see `ProcessMoveService`). Description/keywords/GPS are genuinely shared across a capture
    /// set, but the auto-applied tokens (docs/SPEC.md §6: SOOC keyword, art-filter note) can differ
    /// per file within that same scope — a RAW file gets no SOOC token, a filtered JPEG sibling
    /// does — so targets are grouped by their *computed* (description, keywords) pair and each
    /// group goes out in its own batched `exiftool` invocation, rather than one invocation with
    /// identical values for the whole scope. `ExifToolClient`'s batched write already reports
    /// per-file success/failure without letting one bad file cost its group the write, so this just
    /// relays that per group.
    ///
    /// No-op while a previous save is still running.
    func saveMetadata(scope: MetadataSaveScope) {
        Task { await performSave(scope: scope) }
    }

    /// Does the actual save, returning the final status text (`nil` if a save was already running
    /// or there was nothing to save) — factored out of `saveMetadata(scope:)` so `suggestAI()` can
    /// `await` this directly and fold the outcome into its own status caption, instead of the
    /// caption getting stuck on "saving…" while a fire-and-forget `Task` finishes in the
    /// background.
    @discardableResult
    private func performSave(scope: MetadataSaveScope) async -> String? {
        let targets: [PhotoAsset]
        switch scope {
        case .singleAsset(let asset): targets = [asset]
        case .captureSet(let captureSet): targets = captureSet.members
        case .manualSelection(let assets): targets = assets
        }
        return await writeMetadata(
            description: editableDescription,
            keywords: MetadataEditParsing.parseKeywords(editableKeywords),
            gps: MetadataEditParsing.parseGPS(
                latitudeText: editableLatitudeText, longitudeText: editableLongitudeText,
                altitude: selectedAsset?.gpsAltitude),
            to: targets)
    }

    /// The write itself, on values passed in rather than read off the edit buffer — which is what
    /// lets `runBatchAISuggestion()` save each capture set the model's own answer for that set,
    /// while the panel's buffer still belongs to whichever set the user has selected.
    @discardableResult
    private func writeMetadata(
        description: String, keywords: [String], gps: GPSCoordinate?, to targets: [PhotoAsset]
    ) async -> String? {
        guard !isSavingMetadata, !targets.isEmpty else { return nil }

        isSavingMetadata = true
        saveStatusMessage = "Saving…"
        defer { isSavingMetadata = false }

        await loadArtFilterTokens(for: targets)
        let assetByID = Dictionary(
            uniqueKeysWithValues: captureSets.flatMap(\.members).map { ($0.id, $0) })

        var groupedTargets: [AutoMetadataGroupKey: [(id: PhotoAsset.ID, url: URL)]] = [:]
        for target in targets {
            let asset = assetByID[target.id] ?? target
            let soocToken = AutoMetadataRules.soocToken(for: asset)
            let finalKeywords = AutoMetadataRules.keywordsWithAutoTokens(
                keywords, artFilterToken: asset.artFilterToken, cameraToken: asset.cameraModel,
                lensToken: asset.lensModel, soocToken: soocToken)
            let finalDescription = AutoMetadataRules.descriptionWithArtFilterNote(
                description, artFilterToken: asset.artFilterToken)
            let key = AutoMetadataGroupKey(description: finalDescription, keywords: finalKeywords)
            groupedTargets[key, default: []].append((id: asset.id, url: asset.url))
        }

        let finalStatus: String
        do {
            var failureCount = 0
            var firstFailureReason: String?
            for (key, entries) in groupedTargets {
                let results = try await exifTool.write(
                    description: key.description, keywords: key.keywords, gps: gps,
                    to: entries.map(\.url))
                for entry in entries {
                    let name = entry.url.lastPathComponent
                    switch results[entry.url] {
                    case .success:
                        updateAsset(entry.id) { asset in
                            asset.descriptionText = key.description
                            asset.keywords = key.keywords
                            if let gps {
                                asset.gpsLatitude = gps.latitude
                                asset.gpsLongitude = gps.longitude
                            }
                        }
                    case .failure(let error):
                        failureCount += 1
                        let reason = error.localizedDescription
                        if firstFailureReason == nil { firstFailureReason = reason }
                        Self.saveLog.error(
                            "Save failed for \(name, privacy: .public): \(reason, privacy: .public)")
                    case nil:
                        // Can't happen — `write` returns an entry per URL it was given — but counting
                        // it silently is exactly the bug being fixed here.
                        failureCount += 1
                        if firstFailureReason == nil { firstFailureReason = "no result returned" }
                        Self.saveLog.error("Save returned no result for \(name, privacy: .public)")
                    }
                }
            }
            if failureCount == 0 {
                finalStatus = "Saved to \(targets.count) file(s)."
            } else {
                let reason = firstFailureReason.map { ": \($0)" } ?? "."
                finalStatus =
                    "Saved \(targets.count - failureCount)/\(targets.count) file(s); "
                    + "\(failureCount) failed\(reason)"
                Self.saveLog.error(
                    "Save finished: \(failureCount)/\(targets.count) failed\(reason, privacy: .public)"
                )
            }
        } catch {
            finalStatus = "Save failed: \(error.localizedDescription)"
            Self.saveLog.error("Save failed outright: \(error.localizedDescription, privacy: .public)")
        }
        saveStatusMessage = finalStatus
        return finalStatus
    }
}

/// Groups `saveMetadata`'s write targets by their computed (description, keywords) pair, since
/// `AutoMetadataRules` tokens can differ per file within one save scope — see that method's doc
/// comment.
private struct AutoMetadataGroupKey: Hashable {
    var description: String
    var keywords: [String]
}
