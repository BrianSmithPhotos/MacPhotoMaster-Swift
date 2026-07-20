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
  where possible. One exception stays in the macOS app target rather than Core: `ExifToolClient`
  (below).
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
processed files off the iPad is planned as a separate, not-yet-designed Mac-initiated pull rather than
an iPad-side push into shared cloud storage — `Documents` was chosen specifically because Finder file
sharing (`UIFileSharingEnabled`, not yet added to `project.yml`) can only expose an app's `Documents`
directory, so this leaves that door open without committing to the mechanism yet.

`Timeline.json`-derived GPS suggestion (step 6) is also built and user-verified on the physical iPad
— a location and altitude are suggested for GPS-less photos from the nearest Timeline point, reusing
`TimelineImportParser`/`TimelineLocationCache`/`ElevationLookupService`/`ElevationCache` unchanged;
only the file-access path differs from the Mac (a persisted document-picker bookmark instead of
`TimelineDriveSync`'s Drive-Desktop glob — see "iPad file access" below). Not yet built: reverse
geocoding and AI-assisted suggestions.

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
  library, still unfolded — `ExifToolClient.foldInSidecarIfPresent(for:)` only runs once files reach a
  Mac, same as the existing sidecar design already assumes. The original file on the card never gets
  a sidecar at all.

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

## Provider pattern (AI)

Mirror the reference app's split: a small `AIProvider` protocol (async chat/vision call, given an
image + prompt, returning parsed suggestions) with concrete implementations per backend. Prompting
and response-parsing logic lives in one shared place and stays backend-agnostic; adding a backend
means adding one new type conforming to `AIProvider`. Three backends exist: `OllamaProvider` (local
HTTP daemon), `OpenRouterProvider` (cloud HTTP), and `MLXNativeProvider` (native in-process
inference via `mlx-swift-lm`, no server/daemon/Python involved — see `docs/MLX_PROVIDER.md`).

`SourceBrowserViewModel.eBirdDisabledModels` gates the eBird candidate-species prompt addition
(below) per OpenRouter model string, persisted in `UserDefaults` and editable via a per-model
Toggle in `SettingsView` — the local Ollama/MLX backends always get the candidate list since it
costs nothing extra there, but it's added input-token cost on a paid OpenRouter request, so a few
flagship models default to off. Deliberately not a general model-management system: it's a `Set`
checked against `AIModelSelection.presets`, nothing more.

`OpenRouterProvider`'s API key resolves via `APIKeyStore` (below) rather than reading
`ProcessInfo` directly.

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
`com.briansmithphotos.macphotomaster.apikeys`). The environment-only approach broke for any
GUI-launched process — Xcode's Run button, Finder, and Dock all inherit `launchd`'s environment,
never a shell's `.zshrc` exports — so relying solely on it meant the packaged `.app` silently lost
both keys regardless of what was exported in a terminal. `SettingsView`'s "API Keys" section reads/
writes the Keychain side via `APIKeyStore.read`/`.save`; a `SecureField` is disabled (with an
explanatory caption) when the matching env var is set, since the env var always wins and editing
the field in that case would silently have no effect. Keychain was chosen over `UserDefaults`
because a `UserDefaults`-backed secret is a cleartext plist under `~/Library/Preferences`, not
appropriate for API keys — this is a deliberate exception to this doc's general preference for
storing app state in `UserDefaults`/GRDB rather than the Keychain.

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
