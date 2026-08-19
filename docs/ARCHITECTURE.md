# Architecture

Swift/SwiftUI equivalent of the reference app's `ui/` + `services/` + `workers/` split. See
`SPEC.md` for what the app does; this is about where code should live.

## Layers

- **`Sources/MacPhotoMaster/Views/`** — SwiftUI views, macOS-only. Layout and bindings only, no
  business logic. Equivalent to the reference app's `ui/widgets/`.
- **`Sources/MacPhotoMaster/ViewModels/`** — `@MainActor` `ObservableObject` (or `@Observable`)
  types that hold UI state and call into services, usually via `Task { }`. Equivalent to the
  reference app's `ui/main_window.py` orchestration plus its `workers/` — Swift's structured
  concurrency (`async`/`await`, `Task`) replaces the need for a separate `QRunnable`-style worker
  layer. A view model kicks off an `async` service call in a `Task`, the service does its I/O off
  the main actor, and the result flows back to `@Published` state.
- **`Sources/MacPhotoMasterCore/Services/`** — the actual logic: capture grouping, renaming, AI
  provider calls, timeline/elevation/geocode lookups, and the `MetadataWriter` protocol itself.
  Same role as the reference app's `services/`: no Qt/SwiftUI imports, easy to unit test in
  isolation. Prefer plain `struct`s/`actor`s with `async` functions over classes with mutable state
  where possible. Two exceptions stay in the macOS app target rather than Core: `ExifToolClient`
  and `IPadImportService`, which depends on it concretely (both below).
- **`Sources/MacPhotoMasterCore/Models/`** — plain data types (`PhotoAsset`, `CaptureSet`, etc.),
  `Codable` where they cross a process/network boundary (Timeline JSON, AI provider responses).

## Multi-platform target split

`Package.swift` declares `MacPhotoMasterCore` (a library, portable to any Apple platform, exposed as
a product) and `MacPhotoMaster` (the macOS executable app, depends on Core). The iPadOS app,
`MacPhotoMasterPad`, is *not* a target in this manifest — it lives in its own real Xcode project at
`MacPhotoMasterPad/MacPhotoMasterPad.xcodeproj`, generated from `MacPhotoMasterPad/project.yml` via
[xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`; regenerate after editing
`project.yml` with `xcodegen generate` from that directory), which adds the root package as a local
Swift package dependency (`path: ..`) and consumes the `MacPhotoMasterCore` product.

This split exists because a bare SwiftPM `executableTarget` targeting iOS cannot produce a real,
device-signable `.app` bundle — it builds and runs in the Simulator (no code signing required there),
but `codesign -dv` on the built binary shows "code object is not signed at all" even with
`DEVELOPMENT_TEAM`/`CODE_SIGN_STYLE=Automatic` passed to `xcodebuild`, because there's no
Info.plist/entitlements/embedded-provisioning-profile infrastructure for a bare executable to hang a
real signature on. A genuine Xcode App target has that infrastructure; a SwiftPM executable doesn't.
The macOS app doesn't hit this, since ad-hoc signing (via `scripts/build-app-bundle.sh`) is sufficient
for running locally on the same machine — no physical-device provisioning involved — so it stays a
plain SwiftPM `executableTarget` rather than needing the same treatment. Both app targets/projects
depend on Core and hold nothing but platform-specific Views/ViewModels/entry points.

Installing on a physical iPad (Team ID `U4UCUZRYBD`) is confirmed working end to end: open
`MacPhotoMasterPad/MacPhotoMasterPad.xcodeproj` (not `Package.swift`) in Xcode, select the
`MacPhotoMasterPad` scheme and the device destination, and Run. `MacPhotoMasterPad/project.yml`
hardcodes the Team ID in `DEVELOPMENT_TEAM`/`CODE_SIGN_STYLE: Automatic`; not a secret, but visible
in the repo.

The iPad UI covers source browse through process/move: a two-panel `NavigationSplitView`
(`ContentView`) — source browser (`SourcePanelView`: breadcrumb, subfolder chips, capture-set grid,
skip/un-skip, grid multi-select) on one side, preview + filmstrip (`PreviewPanelView`) on the other,
with an editable metadata form (`MetadataPanelView`) as a resizable sheet rather than a fixed third
column (see "iPad file access" below for why). Folder opening already uses the real `.fileImporter`
picker described there, so it already handles an external volume (SD card reader, camera in
mass-storage mode), not just local app storage. Grid multi-select mirrors the Mac app's
`multiSelectedIDs`/shift-click two ways: a touch-only "Select mode" toggle where tapping a tile
toggles it, and — when a hardware keyboard/trackpad is attached — real cmd-click/shift-click via
`TileTapCatcher`, both writing to the same `PhotoBrowserViewModel.multiSelectedIDs`. See
`TileTapCatcher.swift`'s doc comment for a gesture pitfall worth knowing before adding more custom
touch handling here: stacking a second gesture recognizer over an existing tappable view (even one
that's designed to "decline" and pass touches through) breaks both, because UIKit hit-testing hands a
touch to whichever view is topmost, and a sibling recognizer that isn't an ancestor of the hit-tested
view never sees it at all — one recognizer needs to be the single decision point.

Metadata editing (description/keywords, staged via `SidecarStagingStore` — see "iPad file access"
below), multi-scope Save, a live rename preview (`PhotoBrowserViewModel.titlePreview`, same
`RenameService`-backed design as the Mac app's, driven by a per-session `sessionBatch` label), and
Process & Move (`process(scope:)`, four scope buttons mirroring the Mac app's) are all built and
user-verified on the physical iPad, reusing `MacPhotoMasterCore`'s `MetadataEditParsing`/
`SelectionScope`/`RenameService`/`ProcessMoveService`/`ProcessedStateStore` essentially unmodified —
`ProcessMoveService` is constructed with `NativeMetadataWriter()` in place of the Mac app's
`ExifToolClient()`, otherwise identical. `process(scope:)` patches in any `SidecarStagingStore`-staged
draft that hasn't been reloaded into the current session's edit buffer before calling
`processAndCopy`, so an edit staged in an earlier session is never silently dropped. Process & Move's
destination, `PhotoBrowserViewModel.libraryRootURL`, is a fixed `Documents/ProcessedLibrary` folder
inside the app's own sandbox container — not user-picked, and deliberately not a Google-Drive-mounted
folder (considered and rejected: Drive's background sync writing/evicting bytes in the same folder
`ProcessMoveService` copies into and SHA-256-verifies would race with that verification). Getting
processed files off the iPad is a manual copy rather than an iPad-side push into shared cloud storage
— `Documents` was chosen specifically because both routes off the device can only see an app's own
`Documents` directory: Finder file sharing over USB (`UIFileSharingEnabled`) and the on-device Files
app (`LSSupportsOpeningDocumentsInPlace`), and the Files listing appears only when *both* are set.
`LSSupportsOpeningDocumentsInPlace` comes from `project.yml`; `UIFileSharingEnabled` has no
`INFOPLIST_KEY_` equivalent in Xcode's allowlist — set as a build setting it is silently ignored — so
it lives in a one-key `MacPhotoMasterPad/Info.plist` that `GENERATE_INFOPLIST_FILE` merges into. The
Mac app finishes the job
from there — see "iPad import (Mac side)" below.

`Timeline.json`-derived GPS suggestion (step 6) and reverse geocoding (step 7) are also built and
user-verified on the physical iPad — a location and altitude are suggested for GPS-less photos from
the nearest Timeline point, and once a photo has GPS (embedded or suggested) `ReverseGeocodeService`
merges city/county/state into the keyword edit buffer once per capture set per session. Both reuse
`MacPhotoMasterCore` unchanged (`TimelineImportParser`/`TimelineLocationCache`/`ElevationLookupService`/
`ElevationCache`/`ReverseGeocodeService`); only the Timeline file-access path differs from the Mac (a
persisted document-picker bookmark instead of `TimelineDriveSync`'s Drive-Desktop glob — see "iPad
file access" below). Geocoding reads GPS from the asset rather than an editable lat/long field (the
iPad has none) and, like the Mac, merges keywords into the edit buffer only (they persist on Save,
not automatically). The reverse-geocode `contextText` is stashed per capture-set representative for
the AI step.

AI-assisted suggestions (step 8, first cut) are also built and user-verified: a Suggest button in the
metadata sheet drives `PhotoBrowserViewModel.suggestAI()`, reusing `AISuggestionService` unchanged,
with two providers — native on-device **MLX** (`mlx:`, e.g. FastVLM-0.5B) and **OpenRouter**
(`openrouter:`); Ollama is excluded (no daemon on iPad). The result auto-saves like the Mac, and a
Cancel button interrupts a running MLX generation. Getting on-device MLX to actually run took Metal/
memory work specific to iOS — see `docs/MLX_PROVIDER.md` "On-device (iPad)" (Metal API Validation off,
`increased-memory-limit` entitlement, a `#if os(iOS)` GPU buffer-cache cap in `MLXNativeProvider`, and
`MLX` as a direct package dependency of Core for that). OpenRouter's API key is entered in the iPad
Settings sheet (Keychain via `APIKeyStore`).

Step 8b (pass 1) added prompt profiles and expanded the model roster. `AISuggestionService` builds a
`.full` (unchanged, all Mac/OpenRouter models + gemma-3-4b) or `.compact` prompt; the compact variant
drops the copyable JSON keyword example and gates species-ID on the scene-triage category, for small
on-device models that otherwise echo the placeholder and over-apply bird/flower ID. Profile is chosen
per-model on iPad (`PhotoBrowserViewModel.compactPromptModels`, a Settings toggle, defaulting to
FastVLM). `gemma-3-4b-it-4bit` (~2.5GB, ~5.3GB peak on-device) is registered and is the recommended/
default on-device model; FastVLM-0.5B stays a lighter fallback.

The eBird candidate-species list (8b pass 2) is also wired into the iPad, reusing
`EBirdSpeciesListService`/`EBirdCache`/`EBirdCandidateFormatting` — `lookupBirdCandidates` folds into
the step-7 geocode (decoupled from the geocode memo so setting the `EBIRD_API_KEY` mid-session retries
without a relaunch). Two iPad-specific refinements vs. the Mac: the prompt carries **common names only**
(halving it for the small model), and the Latin binomial is attached afterward by a deterministic
`EBirdCandidateFormatting.attachScientificNames` lookup rather than trusted from the model — whole-word
matched (a wrong-binomial guard), only against the description + the user's trusted keywords (not the
model's own keywords, which can hallucinate a candidate), plural-aware, and inherently additive. See
docs/SPEC.md §6/§7. Subject isolation ("Crop to Subject") now ships on iPad as well: the preview swaps
its zoomable scroll view for a static Fit canvas whose single `DragGesture` overlay draws a rubber-band
crop or, on a tap, picks the Vision instance under the finger via
`SubjectIsolationService.subjectInstanceRect` (mapped through `SubjectCropGeometry`). A possible future
path for rock-solid structured output — Apple Foundation Models / `@Generable` guided generation as an
on-device provider — is recorded in memory, not scheduled.

`ExifToolClient` is the one Service that stays in the `MacPhotoMaster` (macOS) target instead of
moving to Core: it shells out to the `exiftool` binary via `Process`, and process/subprocess
execution isn't available in the iOS/iPadOS sandbox. It conforms to the portable `MetadataWriter`
protocol (Core) alongside `NativeMetadataWriter` (Core, ImageIO `.xmp`-sidecar write, safe on any
platform) — code in Core that needs to write metadata takes `any MetadataWriter` rather than depending
on `ExifToolClient` concretely, so the same call sites work on both platforms.

Moving a type into Core surfaces two access-control traps that don't show up in a single-target
package:

- Every type/member the app targets touch across the module boundary must be explicitly `public` —
  Swift's default `internal` access isn't visible outside its declaring module.
- A `public` type's compiler-synthesized memberwise or no-arg initializer is still only `internal`;
  it needs an explicit `public init` written by hand, even when every stored property is already
  `public`.

Compiling for macOS alone (`swift build`/`swift test`) doesn't catch iOS-only API gaps, since it only
builds for the host platform. Use `xcodebuild -project MacPhotoMasterPad/MacPhotoMasterPad.xcodeproj
-scheme MacPhotoMasterPad -destination "generic/platform=iOS" build` to force a real iOS-SDK compile.
This is how the one genuine cross-platform gap found so far was caught:
`FileManager.homeDirectoryForCurrentUser` is
`API_UNAVAILABLE` on iOS. Both call sites (`MLXModelRegistry`'s oMLX cache-directory lookup,
`TimelineDriveSync`'s Google Drive Desktop path default) are for macOS-only external tools anyway —
oMLX and Google Drive *Desktop* are both Mac apps, not present on iPadOS in that form — so both are
`#if os(macOS)`-gated with a no-op/unreachable fallback rather than genuinely ported. Note the iPad
does have the Google Drive iOS app, but it doesn't mount `My Drive` as real files the way Drive
Desktop does; see "iPad file access" below for how `Timeline.json` reaches the iPad instead.

## iPad file access & sidecar staging

Decided direction for the iPad ingest flow. Folder browsing, sidecar staging, Process & Move, and
`Timeline.json`-derived GPS suggestion are all implemented (see above) — this covers the "Photos via
USB-C", "sidecar write-back", and "`Timeline.json` via Google Drive" bullets below in full. Two
access problems and one behavioral divergence from the Mac app, worked out before writing any of the
actual views:

- **`Timeline.json` via Google Drive.** Implemented (step 6). The iOS/iPadOS Drive app doesn't mount
  a filesystem path the way Drive Desktop does, but it registers as a Files provider, so
  `UIDocumentPickerViewController` can browse into it and pick the file directly — same
  `.fileImporter` SwiftUI modifier the Mac app already uses for folder picking, not a new API. Unlike
  `TimelineDriveSync`'s automatic glob search under `~/Library/CloudStorage` (macOS-only,
  `#if os(macOS)`), the iPad needs a one-time "Locate Timeline.json" step in the new `SettingsView`,
  with the resulting security-scoped bookmark persisted in `UserDefaults` (and re-resolved, re-saving
  if `bookmarkDataIsStale`) so later launches re-import silently without re-prompting. The Drive
  file must have "Available offline" turned on. `PhotoBrowserViewModel.importTimeline(reportStatus:)`
  parses the picked file straight into `TimelineLocationCache` (skipping the Drive copy-down step the
  Mac's `performTimelineSync` does), keyed on the file's (size, mtime) via `isImportNeeded` so an
  unchanged file is a cheap no-op; `suggestGPSIfNeeded()` then applies the nearest match to the whole
  previewed capture set on first view of a GPS-less photo, read-only (no editable lat/long fields,
  unlike the Mac app) but persisted through Save (sidecar) and Process & Move, with an elevation
  lookup chained after via `ElevationLookupService`/`ElevationCache`.
- **Photos via USB-C.** Confirmed working: an OM System body connected in **mass-storage/"USB
  storage" mode** mounts as a plain external volume (`DCIM` + `ALBM` folders, exactly like an SD card
  reader) that Files can browse — the same `.fileImporter(allowedContentTypes: [.folder])` call site
  `SourcePanelView` already has works unchanged for this, no new picker code needed. The camera's
  other USB mode (PTP/MTP "camera connection") must be avoided: iPadOS treats that as a camera and
  only offers the system Photos-style *import* sheet, not a folder browse, which would drop
  non-standard files (sidecars) and RAW originals the app needs direct access to.
- **Sidecar write-back never touches the camera/card.** `NativeMetadataWriter` writes a `.xmp`
  sidecar next to whatever URL it's given (see its doc comment) and is agnostic about where that is
  — but on iPad, "next to the original" deliberately never means *on the card*, even though write
  access there is likely possible. Reasoning: unlike a one-shot SD card import, a card connected this
  way may still be actively written to by the camera between iPad review sessions across a multi-day
  trip (cards commonly aren't reformatted until the camera reports them full) — writing anything to
  that card, even a small sidecar, means carrying interrupted-write/firmware-interaction risk for the
  entire trip instead of a single import session. Instead: `SidecarStagingStore` stages sidecars at
  `~/Library/Application Support/MacPhotoMaster/SidecarStaging/` inside the app's own sandbox,
  keyed by the original filename + file size (not path or capture timestamp — a card that isn't
  reformatted between sessions can have its DCIM folder numbering roll over, so path isn't stable,
  and filename is already what distinguishes shots). `PhotoBrowserViewModel.process(scope:)` reads
  any staged draft back via `stagedDraft(for:)` and patches it into the `PhotoAsset` before Process &
  Move copies the RAW/JPEG bytes off the card (per SPEC.md §5's existing copy-first/verify model);
  `NativeMetadataWriter` then writes a real `.xmp` sidecar next to the copy in the destination
  library, still unfolded — folding it in only happens once the files reach a Mac ("iPad import"
  below), same as the existing sidecar design already assumes. The original file on the card never
  gets a sidecar at all.

  Staged sidecars are never removed by anything in the normal flow — a Process & Move *reads* a draft
  and leaves it in place — so they accumulate for the life of the install, and a re-previewed file
  picks its old draft back up (`applyStagedDraftIfPresent`). That is right for a multi-day trip and
  wrong after a testing session, so `clearStagedDrafts()` plus a confirmed "Clear Staged Edits" button
  in `SettingsView` is the one way to discard them. It deletes with `removeItem` rather than the
  repo's usual trash rule: this is the app's own bookkeeping inside its own container, not the user's
  photographs, and an iOS container has no user-visible trash to recover from anyway.

  Drafts are also hydrated at folder load, not only on preview: `applyStagedDrafts(to:)` patches
  description, keywords and GPS onto every asset in one pass before the grid appears, and logs how
  many it restored. Without it a staged draft only reached `PhotoAsset.descriptionText` when the
  photo was previewed, which broke the multi-day case in two visible ways — the grid showed no sign
  of yesterday's work, and batch AI's "skip sets that already have a description" rule read the
  *original* file's metadata, so a second run re-described sets it had already staged. The grid's
  blue `text.bubble.fill` badge is the other half: it asks
  `BatchAISuggestionTargets.hasDescription`, the same question the batch skip rule asks, so the mark
  on a tile and the sets a run leaves alone can never disagree.

## iPad import (Mac side)

`IPadImportService` finishes off files the iPad processed but couldn't complete — the art-filter
token exiftool alone can read, and the sidecar folded into the image (SPEC.md §5). It lives in the
`MacPhotoMaster` app target rather than Core for the same reason `ExifToolClient` does: it depends on
it concretely, and there is no iPad side of this feature to share with.

The work per file is deliberately thin, because everything downstream of the enrichment is the
existing Mac path: build a `RenameContext` and hand the asset to the ordinary
`ProcessMoveService(metadataWriter: ExifToolClient())`, whose write of title/description/keywords/GPS
into the destination copy *is* the fold-in, and whose `AutoMetadataRules` calls put the art filter
into the keywords. Three pieces were added or lifted into Core to make that possible:

- **`IPadExportNameParsing`** recovers `sequence` and `batch` from an already-renamed file, anchoring
  on the `YYYYMMDD_HHMM` pair. Needed because `RenameService.sequence(from:)` harvests every digit in
  the stem — correct for a camera-original name, but it would swallow the date and time an
  iPad-generated name already carries. The rebuilt `RenameContext` is handed a stand-in URL whose stem
  is just the recovered sequence.
- **`SidecarDraftParsing`** is the XMP-reading half of `SidecarStagingStore`, lifted out so it can
  read a sidecar sitting beside a *destination* file rather than one keyed into the staging
  directory. Chosen over `ExifToolClient.foldInSidecarIfPresent(for:)` here: one fewer process launch
  per file, and it recovers altitude, which that path doesn't request.
- **`PhotoAssetLoader.loadAssets(inTree:)`** walks a whole `<M Month>/<DD>/[jpg/]` tree in one pass.
  The original `loadAssets(in:)` stays single-folder — the browsing grid is deliberately one folder at
  a time.

Sources are trashed (never `removeItem`) only after `ProcessMoveService` has verified the destination
copy, which is what makes a partially failed run safe to re-run over the same folder: it sees only
the leftovers.

A fourth job was added later: redeeming the iPad's **RAW develop marker** (see below). It fits the
same shape — read something out of the sidecar, act on it, hand the result to the ordinary
`ProcessMoveService` — so it is a second `processAndCopy` call rather than a new pipeline.

## RAW develop

`RawDevelopService` (Core) renders a RAW to a JPEG via `CIRAWFilter` +
`CIContext.writeJPEGRepresentation`, choosing a decoder per file (SPEC.md §5 "RAW develop"). The
platform split follows `MetadataWriter`/`ExifToolClient` exactly: the service takes an optional
`any DNGConverting`, and the only implementation, `AdobeDNGConverter`, lives in the `MacPhotoMaster`
app target because it shells out to a Mac-only application. An absent converter is not an error — it
makes the service fall back to the newest decoder the file itself offers.

- **`decoderVersion` is always set explicitly.** Apple documents the default as the newest available
  version, but an X-T5 `.RAF` that lists `9` as supported still opens at `8`. Trusting the default
  would silently ship a decoder-8 render from the one camera that doesn't need the DNG detour.
- **`CIRAWFilter(imageURL:)` is not a validity gate.** It returns a filter for any readable file,
  including a text file, and only then reports `["None"]` as its decoder list with a zero
  `nativeSize`. Screening for a numbered decoder is what actually says "this is a RAW this OS can
  develop".
- **The DNG detour loses the original's `BaselineExposure`.** Adobe's converter writes its own, and
  Apple's decoder honours whatever the DNG says. Measured across the three sample files: the OM-3
  (0.50) and X-T5 (0.10) come through unchanged, but the X-E4's +1.02 — Fuji's ISO offset — is
  rewritten to -0.70, rendering about 1.7 stops dark (mean luminance 0.489 direct, 0.227 via DNG,
  against an embedded camera preview of 0.489). `developViaDNG` therefore copies the original
  filter's `baselineExposure` onto the DNG's, which restores the X-E4 and is a no-op for a file the
  converter left alone. `testDevelopViaDNGMatchesTheDirectRenderExposure` guards it.
- **`RawDerivedStore`** stages derivatives under Application Support, keyed `<size>_<originalName>`
  — same key ordering as `SidecarStagingStore`, for the same `deletingPathExtension()` collision
  reason documented there.
- **`PhotoAsset.derivedFrom`** does three jobs at once: it marks an asset as derived (suppressing
  `sooc`), names the original whose filename the rename must be built from (the staging key's digits
  would otherwise be harvested as a sequence), and keys the store. `CaptureSet.representative`
  deliberately prefers a non-derived member so developing a file never changes which tile represents
  its set — skip and processed state are keyed by representative path.
- **The decoder token lives in the derivative's keywords**, not in memory: a staged derivative
  outlives the session that made it, and recomputing the token would mean decoding the RAW again.
  `RawDevelopService.token(in:)` reads it back for the filename's art-filter slot at process time.
- **iPad**: no DNG output type exists in ImageIO there, so the iPad only stages
  `RawDevelopService.developMarkerKeyword` into the sidecar. That reuses an existing end-to-end
  channel (staged sidecar → Process & Move → destination `.xmp` → `IPadImportService`) rather than
  adding a transport, which is the whole reason a keyword was chosen over a marker store.

## Preview overlays and where the photo actually is

Anything anchored to the previewed *photo* rather than to the preview pane — the camera-look strip
(SPEC §1) is the current example — must take the image's on-screen rectangle from
`ZoomScrollView.visibleImageFrame`, published through `ZoomableImageView`'s `visibleImageFrame`
binding. Do not recompute it from the enclosing `GeometryReader`'s size. That was tried, and it is
wrong twice over:

- `NSScrollView`'s legacy scrollers inset `contentView` by their **full width** (17pt each on this
  OS, not the 15 or 16 you might assume), and they autohide, so the photo's right edge sits 0, 17 or
  34pt inside the pane's own edge depending on the current zoom and the image's aspect. Nothing
  outside the scroll view knows which of those applies, so any constant an overlay picks is a fudge
  that happens to look right at one zoom.
- Arithmetic centring lands on fractional points while the image is *drawn* on the backing-store
  pixel grid, so the published rect goes through
  `backingAlignedRect(_:options: .alignAllEdgesNearest)`. Half a point of disagreement is a whole
  device pixel, and which way it rounds relative to an anchor depends on the pane's width — the
  symptom is an overlay whose gap looks right at one pane size and a pixel tight at the next.

Two things that make the plumbing shorter than it looks: `NSScrollView` is a **flipped** view, so
`contentView.frame` is already in SwiftUI's top-left space and needs no conversion; and crop mode
has no scroll view and a fixed zoom, so `SubjectCropGeometry.fitRect` describes it exactly there.
The frame is reported from `layout()` and from both magnification paths, each hopping one runloop
turn before writing the binding, for the same "Modifying state during view update" reason as the
zoom and centre bindings beside it.

## Camera-look visualiser (where its pieces live)

The visualiser (SPEC §1) spreads across every layer, and the split is worth stating because most of
it is *data* rather than code, and that data was expensive to obtain:

- `Models/CameraLook.swift` — the parsed value type. What the photographer changed, so a control
  left at zero is absent rather than present-and-zero. Anything needing the full set (the curve's
  hover list wants every dial including the untouched ones) reconstructs it rather than expecting
  the parser to carry it.
- `Services/CameraLookParsing.swift` — maker notes to `CameraLook`. Keeps the three B&W routes
  strictly apart: they use three different numberings for the same option lists, so sharing a table
  turns orange into red.
- `Models/CameraLookGeometry.swift` — the **measured** ring geometry: Colour Profile spoke centres,
  Partial Color band shapes and floors, Colour Creator hues. Hand-written from the measurement
  write-ups, with the provenance in the doc comments.
- `Models/CameraLookToneCurves.swift` — **generated**, not written. `scripts/label-tone-curves.py`
  emits it from `scripts/curves/`. Do not hand-edit it; change the script or the measurements.
- `Models/CameraLookToneComposite.swift` — the composition rules (tone dials add, contrast is a
  serial stage applied first, Gradation overrides contrast entirely). Each rule is a measured result,
  not arithmetic, and each has a test naming what it would mean to get it backwards.
- `Models/CameraLookRendering.swift` — which hero graphic a look calls for. Two display *judgements*
  live here rather than in the view, because both are about the data: merging the three B&W routes,
  and letting a live reading beat a stale one.
- `Views/CameraLookStripView.swift` — drawing only, in a `Canvas`. No decisions about what a look
  means; if a question needs answering about the data, it belongs in one of the above.

The measurement programme behind all of it — shot lists, tooling, results, and the runs that had to
be thrown away — is in `scripts/README.md`. Anything that changes a number the visualiser draws
should start there rather than in Swift.

## Concurrency rules

- Never call `exiftool`, hit the network, or touch the filesystem from a SwiftUI `View` body or a
  `@MainActor`-isolated function directly — route it through a `Service` call from a `Task`.
- Services that do I/O should be `async` and safe to call from a background context; mark them
  `Sendable` where the compiler asks.
- UI state mutation (`@Published` updates) must happen back on the main actor — either the
  ViewModel method itself is `@MainActor` and simply `await`s the service call, or you explicitly
  hop back with `await MainActor.run { }`.

## exiftool integration

Same approach as the reference app: `exiftool` is an external binary invoked via `Process`
(Foundation's subprocess API), not a hand-rolled EXIF/IPTC/XMP parser. Wrap it in one service
(`ExifToolClient` or similar) that all read/write paths go through.

exiftool's per-invocation cost is dominated by its own process/Perl-interpreter startup, not the
actual file read/write — reading or writing N files one at a time is roughly N times slower than
doing them in one invocation (~15x measured on a 20-file sample in the reference app). Batch
multi-file operations (importing a card, saving a capture set) into as few `exiftool` invocations
as possible:

- **Reads**: pass every path as a trailing argument to one `exiftool -j -G1 -a -s file1 file2 ...`
  call; the JSON array comes back with one object per file, keyed by that object's `SourceFile`
  tag. Chunk large batches so one invocation's runtime/output stays bounded.
- **Narrow reads**: when only a handful of tags are wanted, name them (`-DriveMode -StackedImage
  ...`) and add `-n` for the camera's raw numbers rather than exiftool's prose. Output shrinks
  enough to justify a much larger chunk size — `readGroupingSignals(at:)` reads a whole folder's
  capture-grouping signals in a couple of launches, which is what makes running it on every folder
  load affordable. The signals it reads live in Olympus maker notes, which ImageIO exposes no
  dictionary for at all, so the iPad reads the same five tags out of the file's bytes instead
  (`OlympusMakerNoteReader`). Both apps have to wire it in separately, since they are separate
  projects with separate view models: `SourceBrowserViewModel.groupingSignals(for:)` fills in with
  it wherever exiftool didn't answer, and `PhotoBrowserViewModel.load(_:)` calls it directly. It reads the
  first 64KB of a frame rather than the whole of it, and checks completeness against the bytes it
  actually walked rather than the maker note's declared length — the note declares 1.8MB on a
  camera-original ORF because Olympus embeds a preview in it, while everything grouping needs ends
  12,608 bytes in. Through iPadOS's file provider that distinction is the whole cost of a folder
  load: every byte crosses the cable, and the file cannot be memory-mapped the way a mounted card's
  can. Deliberately not a general maker-note decoder: everything
  grouping needs lives in one Olympus `CameraSettings` subdirectory, and anything wider belongs to
  exiftool on the Mac.
- **Writes**: only batch files that share byte-identical target tag values — pass the shared
  `-TAG=value` args once followed by every target path. Group files by their value-tuple first;
  files needing a unique per-file value (e.g. a rename-derived title) can't be grouped and should
  stay one invocation per file.
- **Partial failure**: never let one bad/slow file fail the whole batch. On any batch miss,
  failure, or timeout, fall back to a per-file retry for just the affected path(s) rather than
  trying to parse exiftool's partial-failure output. For writes, restore backups for the whole
  group before falling back.

See `ExifToolClient.readMetadata(at: [URL])` for the reference implementation of this pattern.

macOS 27 (Golden Gate, 2026) note: nothing in that release changes this. ImageIO/`CGImageDestination`
gained no new EXIF/IPTC/XMP write coverage, and Core Image RAW 9's demosaic/denoise improvements
live in `CIRAWFilter`, not in metadata read/write — see `NativeMetadataReader`'s header doc for detail.
`exiftool` stays the only reliable read/write path for maker-note fields and metadata writes.

### Resolving the exiftool binary — don't rely on `PATH` alone

macOS launches `.app` bundles (Dock, Finder, `open`) with a minimal `PATH`
(`/usr/bin:/bin:/usr/sbin:/sbin`) that excludes Homebrew's install directories. Code that runs
`exiftool` via `env`/bare-name `PATH` lookup works fine from `swift run` or Xcode (both inherit the
launching shell's full `PATH`) but fails with an unhelpful launch error the moment the same binary
ships as a double-clickable app — and since capture grouping, metadata reads, and preview
extraction all shell out to exiftool, this kind of PATH failure breaks all three at once with no
single obvious cause. Resolve the real path once (check `PATH` first, then fall back to
`/opt/homebrew/bin/exiftool` / `/usr/local/bin/exiftool`) and launch that resolved path directly
instead of going through `env`. See `ExifToolClient.exiftoolPath` for the reference implementation.

## Local cache (Timeline GPS matching)

The reference app caches an imported Google Timeline export in local SQLite for nearest-timestamp
GPS matching (see `SPEC.md` §7). This app uses **GRDB.swift** for the same job rather than
SwiftData: the query shape — nearest timestamp within a bounded window, tie-broken by source-type
reliability then reported accuracy — is a `CASE`/`ORDER BY` SQL query that doesn't map cleanly onto
SwiftData's `#Predicate` macros, and the schema is a near-literal port of the reference app's
existing cache tables. `TimelineLocationCache` (an `actor`, since GRDB's `DatabaseQueue` is
thread-safe but the cache also needs its own serialized read/write ordering) is the reference
implementation: idempotent import via a `timelineImport` signature table (source path/size/mtime),
upsert-by-`recordKey` into `timelinePosition` so re-imports update rows in place, and the
bounded-window nearest-match query. `TimelineSample` mirrors the reference app's `_TimelinePosition`
and reuses its `record_key` hash scheme (SHA-1 over timestamp/lat/lon/altitude/source/accuracy) —
not because the two apps share a database, but so the two implementations stay easy to compare.

`TimelineImportParser` parses a raw Timeline JSON export into `TimelineSample` values (matching the
reference app's `_parse_timeline_positions`), preferring `rawSignals[].position` entries (richer:
accuracy/source/altitude) and falling back to `semanticSegments[].timelinePath[]` points (coarser,
tagged `TIMELINE_PATH`, no altitude/accuracy/source). A malformed or partial record is skipped
rather than failing the whole parse; the result feeds `TimelineLocationCache.importSamples`.

Import cost is a real constraint, not a micro-optimisation: an export has one record per timestamp
and hundreds of thousands of them. Measured on a 13.6 MB / 100k-record synthetic export,
`JSONSerialization` accounts for 0.14s of it and the rest was Foundation calls made per record —
`ISO8601DateFormatter.date(from:)` at ~63 microseconds a call (6.3s), and `String(format:)` inside
`TimelineSample.recordKey` (2.2s). Both now have hand-rolled fast paths (a byte scanner for the
timestamp, falling back to the formatters for any shape it doesn't recognise; a hex table for the
digest), taking that export from ~10s to ~1.5s (release build, M1 Ultra). The record key's *text* is a persisted format —
it is the upsert key in `timelinePosition` — so `TimelineSampleRecordKeyTests` pins two digests
computed independently, and a rewrite that changed the key would re-import an unchanged export as a
database full of new points rather than failing visibly.

Both apps run the parse and the file hash in a `Task.detached`. They are synchronous, second-scale
work called from a `@MainActor` view model, so on the main actor they freeze the UI — on the iPad
during the launch import, before there is anything on screen to explain the wait. The iPad shows a
`ProgressView` in the toolbar while `isImportingTimeline` is true for the same reason.

## Per-folder session state

Three small GRDB actors share `TimelineLocationCache`'s shape and hold the user's per-folder
editorial decisions: `SkipStateStore` (`skip_state.sqlite3`), `ProcessedStateStore`
(`processed_state.sqlite3`) and `CaptureSetMergeStore` (`capture_set_merges.sqlite3`). All three live
in Application Support rather than in the source folder, because the source is usually an SD card
that will be ejected and reformatted while the decisions about that shoot should outlive it. All
three key on `(folderPath, assetPath)` — never on a `CaptureSet.ID`, which is regenerated on every
load — so their state survives regrouping as well as reopening.

Both browsers derive what they display from these in one chain, in `rederiveCaptureSets()`:
grouping's own answer (`automaticCaptureSets`) -> `CaptureSetMerging.apply` -> `SkipPartition.split`.
Nothing writes to the published arrays directly, and in-memory asset mutations go to the pre-merge
array so that splitting a merged set apart cannot discard an unsaved metadata edit.

## Provider pattern (AI)

Mirror the reference app's split: a small `AIProvider` protocol (async chat/vision call, given an
image + prompt, returning parsed suggestions) with concrete implementations per backend. Prompting
and response-parsing logic lives in one shared place and stays backend-agnostic; adding a backend
means adding one new type conforming to `AIProvider`. Four backends exist: `OllamaProvider` (local
HTTP daemon), `OpenRouterProvider` (cloud HTTP), `MLXNativeProvider` (native in-process
inference via `mlx-swift-lm`, no server/daemon/Python involved — see `docs/MLX_PROVIDER.md`), and
`FoundationModelsProvider` (Apple on-device Foundation Models via `@Generable` guided generation).

`FoundationModelsProvider` is the one backend whose output shape is *guaranteed* rather than parsed
hopefully: its `@Generable PhotoMetadata` schema returns a typed `{description, keywords, species}`
value, which it serializes to JSON to cross the shared `chat -> String` seam unchanged. Callers pass
`PromptProfile.guided` (the `.full` prompt minus the "return JSON" framing, plus a line pointing at
the typed `species` field), and `AISuggestionResult.species` carries the field into the iPad's eBird
`attachScientificNames` binomial lookup. It requires the macOS 27 / iOS 27 SDK (Xcode-beta) to build
because Foundation Models image input is only there; the OS floor is enforced at runtime via
`#available`, so the other three backends still work below 27. See CLAUDE.md "Hardware & model notes"
for the toolchain constraint.

`SourceBrowserViewModel.eBirdDisabledModels` gates the eBird candidate-species prompt addition
(below) per OpenRouter model string, persisted in `UserDefaults` and editable via a per-model
Toggle in `SettingsView` — the local Ollama/MLX/Foundation backends always get the candidate list
since it costs nothing extra there, but it's added input-token cost on a paid OpenRouter request, so
a few flagship models default to off. Deliberately not a general model-management system: it's a `Set`
checked against `AIModelSelection.presets`, nothing more.

`OpenRouterProvider`'s API key resolves via `APIKeyStore` (below) rather than reading
`ProcessInfo` directly.

## Batch AI suggestions

`SourceBrowserViewModel.runBatchAISuggestion()` runs one suggestion per capture set over many sets.
The only part with a silent failure mode — *which* sets a run covers — lives outside the view model
as `BatchAISuggestionTargets` in Core, pure and unit-tested, because describing a set the user meant
to keep (or skipping one they meant to describe) is invisible until the files are written.

Three decisions worth keeping:

- **Serial, not concurrent.** Every backend is a single model answering one request at a time —
  local ones are bound by the one Metal/Ollama context, and firing an OpenRouter batch in parallel
  just buys rate limits. A `TaskGroup` here would add contention, not throughput.
- **Save as you go.** Each set is written the moment its answer comes back, so Stop keeps everything
  already done and a failure costs only its own set (the loop records the first reason and carries
  on). This is why `performSave(scope:)` was split: `writeMetadata(description:keywords:gps:to:)`
  writes *passed-in* values, since the panel's edit buffer belongs to whichever set the user has
  selected, not to the set the batch is currently on.
- **A batch locates a photo the same way a person would.** `ensureAIContext(for:)` prefers the
  representative's own embedded coordinates and falls back to the Timeline point for its capture
  time — the same bounded-window query `suggestGPSIfNeeded()` runs on the photo on screen, and now
  with the same consequences: the coordinate feeds the prompt (the location line, and the eBird
  region the candidate species come from), becomes location keywords, and is written. The Mac hands
  it back for `writeMetadata(description:keywords:gps:to:)` to write with the rest; the iPad applies
  it to the set's members, so it stages, shows in the panel and reaches Process & Move, all three of
  which read GPS off the asset. Altitude is looked up for it rather than taken from Timeline
  (SPEC.md §7). Two earlier cuts are worth not repeating. The first had no fallback at all, so on a
  camera that records no GPS every set was described with no idea where it was taken and no list of
  species that live there — the condition where the prompt asks a small model for a Latin binomial
  and gets an invented one, since it is the presence of a candidate list that switches the prompt to
  "name it from this list, do not write a scientific name". The second read the fallback but refused
  to write it, on the grounds that a batch runs with nobody watching; with a GPS-less camera that
  fired on every photo, and the result was that whether a shoot ended up located came down to which
  sets the user had happened to open first. The location keywords are returned rather than parked in
  the edit buffer either way, because a batch has no buffer for them to survive in.

The single-set path (`suggestAI()`) and the batch share `aiSuggestion(...)` — prompt profile choice,
eBird candidates, the Foundation-Models skip, and species enrichment — so the two cannot drift.

`PhotoBrowserViewModel` carries the same three methods for iPad, against the same Core rule. Three
differences, all from the platform rather than the feature: writes go through `SidecarStagingStore`
(`writeMetadata(description:keywords:to:)` — no `gps` parameter, since each staged sidecar takes GPS
from its own asset), the scope is `displayedCaptureSets` so a run cannot reach sets the Active/Skipped
picker is hiding, and serial execution matters more — `mlx:` and `foundation:` are one on-device model
under a jetsam ceiling, where overlapping generations get the app killed rather than finishing sooner.
Touch selection needs nothing special: iPad fills `multiSelectedIDs` only in Select mode, so a
selection is always deliberate there, and the shared two-or-more threshold already matches what
`hasMultiSelection` gates everywhere else in that app.

## eBird species-list cache

`EBirdSpeciesListService` (network client for eBird's taxonomy/subnational2-region/species-list
endpoints, API key via `APIKeyStore` — below) feeds
`EBirdCache` (a GRDB actor mirroring `ElevationCache`'s shape — caller-enforced TTLs, 30 days for a
region's species list, 90 days for the taxonomy) and `EBirdCandidateFormatting` (pure functions:
county-name-to-region-code matching, and building a capped "Common Name (Genus species)" candidate
string). `SourceBrowserViewModel.lookupBirdCandidates` resolves a capture set's county first
(falling back to the bare state region code), fetches/caches, and stores the formatted list keyed
by capture-set representative for `suggestAI()` to pass into `AISuggestionService.suggest`'s
`birdCandidateSpecies` parameter — a verified-locally-recorded species list the model is told to
strongly prefer over free recall. Not part of `docs/SPEC.md` or the reference app; added purely to
improve wildlife-ID accuracy. Every no-op/failure branch logs why (`os.Logger`, category
`"EBirdSpecies"`) — this integration's first real-world test silently produced a fabricated species
name because `EBIRD_API_KEY` never reached an Xcode-launched process (shell `.zshrc` exports don't
propagate there), so the failure path is deliberately loud now rather than a silent `try?`.

## API key storage (`APIKeyStore`)

`APIKeyStore` resolves both `EBIRD_API_KEY` and `OPENROUTER_API_KEY` from the process environment
first, then falls back to the macOS Keychain (`kSecClassGenericPassword`, service
`photos.briansmith.macphotomaster.apikeys`, accounts `EBIRD_API_KEY`/`OPENROUTER_API_KEY` — opaque
`kSecAttrService`/`kSecAttrAccount` lookup keys, nothing derives them from the bundle ID at runtime).
The environment-only approach broke for any
GUI-launched process — Xcode's Run button, Finder, and Dock all inherit `launchd`'s environment,
never a shell's `.zshrc` exports — so relying solely on it meant the packaged `.app` silently lost
both keys regardless of what was exported in a terminal. `SettingsView`'s "API Keys" section reads/
writes the Keychain side via `APIKeyStore.read`/`.save`; a `SecureField` is disabled (with an
explanatory caption) when the matching env var is set, since the env var always wins and editing
the field in that case would silently have no effect. Keychain was chosen over `UserDefaults`
because a `UserDefaults`-backed secret is a cleartext plist under `~/Library/Preferences`, not
appropriate for API keys — this is a deliberate exception to this doc's general preference for
storing app state in `UserDefaults`/GRDB rather than the Keychain.

The `service` string was `com.briansmithphotos.*` (the app's never-owned pre-2026-07 bundle domain)
until 2026-07-24, when it was realigned to the current `photos.briansmith.*` bundle ID during a
deliberate keychain reset — the name shown in the macOS keychain access prompt is this `service`
string, so the old value read as a mismatched app. Renaming a `kSecAttrService` key strands
already-saved items (nothing migrates them), so it was only safe to change while the reset was
already forcing the keys to be re-entered. That reset also cured a recurring "wants to use your
confidential information" prompt: the login keychain's default per-item ACL is pinned to the specific
signed app that *created* the item (unlike TCC grants, which key on the stable designated
requirement and so survive rebuilds under the cert-backed signing), so keys created under an earlier
signing context re-prompt forever; deleting them and re-saving from the current cert-signed bundle
makes that bundle the owner, and an owner reads its own items without any prompt.

`service` is a `var` rather than a `let` for one reason: **tests must not touch the real items.**
`EBirdSpeciesListServiceTests` and `OpenRouterProviderTests` need `resolve`'s Keychain fallback to
find nothing, and until 2026-08-11 they achieved that by deleting the real item in `setUp` and
saving it back in `tearDown`. That re-created it through `SecItemAdd`, whose default ACL makes the
calling process the sole owner — the test binary, not the app — so the app prompted on its next
read, once per suite run, which reads as once per build. The restore path was also a data-loss
route: `save(nil)` is a delete, so a read that came back nil quietly destroyed both keys. They now
point `service` at a throwaway name for the duration; nothing is written under it, so no item is
created at all. `APIKeyStoreTests` guards the property this depends on — that `service` is honoured
by read, save and delete alike — since hardcoding it back into any one of them would restore the old
behaviour with every other test still green. Any future test needing the Keychain should do the
same, and never operate on the production service name.

## File safety

- Deleting a file goes through `NSWorkspace.shared.recycle(_:completionHandler:)` (or
  `FileManager.trashItem`), never `FileManager.removeItem`.
- Verify a copy (size + SHA-256, `CryptoKit.SHA256`) before treating a source file as safely
  handled — see `SPEC.md` §5.

`ProcessMoveService` is the reference implementation of this section for the copy/move step
(`SPEC.md` §5): it copies a source into `<library>/<M Month>/<DD>/` (JPEGs one level deeper into
`jpg/`, matching the reference app's destination routing), verifies size + SHA-256 before writing
metadata to the destination, and trashes the partial destination copy — never the source — on any
verification or write failure. It composes `RenameService` (destination filename) and an injected
`any MetadataWriter` (destination metadata write — `ExifToolClient` on macOS; see "Multi-platform
target split" above); scope resolution (single/capture-set/selection/session) and skip-on-success
wiring are left to the calling ViewModel.

## Testing

Favor testing the `Services/` and `Models/` layers directly (pure logic, no UI) — this is where the
reference app's test suite concentrates its coverage (see its `docs/TESTING.md` for the shape of
what's worth covering: field-mapping, grouping decisions, rename pattern generation, destination
routing, JSON/response parsing, coordinate/timestamp matching — not widget wiring).
