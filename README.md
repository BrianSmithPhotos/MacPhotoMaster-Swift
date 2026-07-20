# MacPhotoMaster (Swift)

A from-scratch Swift/SwiftUI reimplementation of [MacPhotoMaster](https://github.com/BrianSmithPhotos/phototags)
(a Python/PySide6 app), taken on as a way to learn both Swift and SwiftUI. Not a port — see
`docs/SPEC.md` for the product spec this is building toward, and `docs/ARCHITECTURE.md` for how
code should be organized. Both are self-contained; you don't need the Python sibling repo to work
in this one.

## Requirements

- macOS 14+
- Xcode (recommended, for SwiftUI Previews) or the Swift toolchain via Xcode Command Line Tools
  (`xcode-select --install`) if working from another editor.
- [`exiftool`](https://exiftool.org/) on `PATH` (`brew install exiftool`) — all metadata read/write
  goes through it, same as the Python sibling app.
- Optional, for AI-assisted suggestions: a running [Ollama](https://ollama.com) server with a
  vision-capable model, and/or an [OpenRouter](https://openrouter.ai) API key (see
  `docs/SPEC.md` §6). A third, native in-process MLX backend (`mlx-swift-lm`, no server/API key
  needed) is also available — see `docs/MLX_PROVIDER.md`. If a model is already downloaded via
  [oMLX](https://github.com/BrianSmithPhotos/omlx)'s model manager (its downloader is the more
  robust of the two), `MLXModelRegistry` picks it up straight from oMLX's local store instead of
  re-downloading multi-GB weights a second time — see `docs/MLX_PROVIDER.md` "Sharing downloads
  with oMLX".
- Optional, for eBird-verified bird-species candidate lists in AI prompts: an
  [eBird](https://ebird.org) API key.
- Both API keys are entered in Settings (Cmd+,) > API Keys, where they're stored in the macOS
  Keychain via `APIKeyStore` — this is the reliable path for GUI-launched builds (Xcode's Run
  button, Finder, Dock), none of which inherit a shell's `.zshrc` exports. Setting the process
  environment variable directly (`EBIRD_API_KEY` / `OPENROUTER_API_KEY`) still works and takes
  precedence over the Keychain, which is convenient for `swift run`/terminal debugging.

## Getting started

Open `Package.swift` directly in Xcode, or from the command line:

```sh
swift build
swift run
swift test
```

`swift run` launches the app as a plain process — no custom icon/Dock identity, and a fresh ad-hoc
code-signing identity on every rebuild, so macOS privacy grants (e.g. Files and Folders access to a
Google Drive folder for Timeline sync) tied to that signature can need re-granting. Fine for
day-to-day development.

For a real, Dock-pinnable app, run `scripts/build-app-bundle.sh` — see `scripts/README.md`
"build-app-bundle.sh" — which builds `dist/MacPhotoMaster.app` (ad-hoc signed, not notarized/
Developer ID, so it's for running on this machine, not distributing to others). It builds via
`xcodebuild` rather than `swift build -c release`: mlx-swift-lm's Metal shaders only get compiled
into `default.metallib` by Xcode's build system, so a plain SwiftPM release build ships without it
and the app silently aborts (no crash report) on first MLX use.

## Status

Past the skeleton stage — the core ingest workflow from `docs/SPEC.md` works end to end:

- **Source browsing** (§1): folder navigation, capture-set grouping (RAW+JPEG pairs grouped by
  capture timestamp), a Stacked thumbnail grid, capture-group-aware multi-select, and a preview
  filmstrip with ring-selection. Skip/un-skip is persisted per folder, with an Active/Skipped
  segmented filter to review and restore skipped items.
- **Metadata read/write** (§2–3): full EXIF/IPTC/XMP read and dual-tag write via `ExifToolClient`,
  batched across files, idempotent keyword writes, and save scopes for a single file, a capture
  set, or the current manual selection.
- **Rename** (§4): deterministic destination filenames, including the in-camera art-filter token
  parsed from maker notes.
- **Process & move** (§5): verified copy (size + SHA-256) to a library folder routed by file type,
  with a persisted, non-blocking "processed" checkmark badge on the source grid and preview
  filmstrip (`ProcessedStateStore`) so a re-opened folder still shows what's already gone through
  once — it never prevents reprocessing. Auto-skipping successfully processed files (per
  `docs/SPEC.md` §5) isn't wired yet.
- **AI-assisted suggestions** (§6): pluggable provider interface with three backends — local
  Ollama, cloud OpenRouter, and a native in-process MLX backend (`mlx-swift-lm`, see
  `docs/MLX_PROVIDER.md`) — vision pre-check, retry-with-crop fallback, and group-aware
  description/keyword application. Wildlife/plant identification is improved beyond the base spec
  via a "Crop to Subject" toggle (crops to `SubjectIsolationService`'s Vision-detected subject
  before sending, or a user-drawn rectangle on the preview overriding it — see the toggle's doc
  comment on `SourceBrowserViewModel.subjectIsolationEnabled`), and via an eBird region-species
  candidate list (see `EBirdCandidateFormatting`) that verified-locally-recorded
  species are drawn from instead of free model recall — gated off by default for a few
  flagship/pay-per-token OpenRouter models to control input-token cost (per-model toggle in
  Settings, Cmd+,), always on for the local Ollama/MLX backends.
- **GPS enrichment from Google Timeline** (§7): Drive-synced `Timeline.json` imported idempotently
  into a local GRDB/SQLite cache, nearest-timestamp matching within a bounded window, ground-truth
  elevation lookup (never trusting Timeline altitude), and reverse geocoding for location keywords
  and AI prompt context. Sync runs on launch, on folder navigation, and via a manual "Refresh
  Timeline" button in Settings (Cmd+,).
- A native, read-only `NativeMetadataReader` (ImageIO-based) exists alongside `ExifToolClient` as a
  faster-path prototype for reads/previews — see its header doc for scope.
- The Metadata pane is a `.inspector()` (not a third `NavigationSplitView` column), giving it the
  same translucent sidebar material as the Source pane plus a native collapse toggle in the toolbar.
- `scripts/build-app-bundle.sh` packages a real, ad-hoc-signed `MacPhotoMaster.app` (custom icon,
  stable identity across rebuilds, built via `xcodebuild` so mlx-swift-lm's Metal shaders compile
  correctly) that can be pinned to the Dock — not a substitute for `swift run` during day-to-day
  development, just the way to get a Dock-launchable build.
- API keys (eBird, OpenRouter) resolve from the process environment first, then fall back to the
  macOS Keychain via `APIKeyStore`, with a Settings (Cmd+,) > API Keys section to store them —
  fixes GUI-launched builds (Xcode Run button, Finder, Dock) never seeing shell-exported env vars.

Not yet built: a notarized/Developer ID-signed `.app` for distributing beyond this machine, and the
deferred items noted in `CLAUDE.md` (ImageIO metadata write-back).

**iPadOS target**: `Package.swift` builds a portable `MacPhotoMasterCore` library (all Services/Models
except `ExifToolClient`, which needs `Process`/subprocess execution unavailable on iOS) plus the
`MacPhotoMaster` macOS app. The iPadOS app lives outside the manifest, in its own Xcode project at
`MacPhotoMasterPad/MacPhotoMasterPad.xcodeproj` (generated via `xcodegen` from `project.yml` in that
directory), which depends on `MacPhotoMasterCore` as a local Swift package — a bare SwiftPM
`executableTarget` can't produce a real, device-signable `.app` bundle for iOS, so it needed a genuine
Xcode App target instead. See `docs/ARCHITECTURE.md` "Multi-platform target split" for the rationale
and the access-control/API-availability gotchas hit along the way. Confirmed installing and launching
on a physical iPad.

The iPad ingest workflow (source browse through process/move) is built and user-verified end to end:
two-panel `NavigationSplitView` (source browser + preview/filmstrip), editable metadata form (Save
scopes: this file / capture set / current selection), a live rename preview driven by a per-session
"Batch" label, and Process & Move (four scope buttons: single image / capture set / current
selection / session), with a persisted "processed" checkmark badge mirroring the Mac app's. Metadata
edits are staged via `SidecarStagingStore` (never written straight to the source, which may be a
read-only or actively-in-use camera card) and folded in at Process & Move time. `NativeMetadataWriter`
(ImageIO `.xmp` sidecar) is the write path throughout, since `exiftool` can't run on iOS. Process &
Move's destination is a fixed local folder inside the app's own sandbox (`Documents/ProcessedLibrary`)
rather than a user-picked one — a Google-Drive-mounted folder was considered and ruled out (Drive's
background sync could race with `ProcessMoveService`'s own copy+verify), and the eventual off-device
transfer is planned as a separate, not-yet-designed Mac-initiated pull rather than an iPad-side push.
See `docs/ARCHITECTURE.md` "iPad file access & sidecar staging" for the full reasoning.

`Timeline.json` GPS suggestion (step 6) and reverse geocoding (step 7) are also built and
user-verified: a Settings sheet locates `Timeline.json` in the Google Drive Files provider once
(persisted as a security-scoped bookmark and re-imported silently on later launches), GPS-less photos
get a location and altitude suggested from the nearest Timeline point — read-only on iPad, but
persisted through Save and Process & Move — and once a photo has GPS, city/county/state are merged
into the keyword field via OpenStreetMap Nominatim. AI-assisted suggestions (step 8, first cut) are
also built and user-verified: a Suggest button in the metadata sheet with two providers — native
on-device MLX (`mlx:`, e.g. FastVLM-0.5B, which runs in seconds on the M4 iPad) and OpenRouter
(`openrouter:`, key entered in Settings); Ollama is excluded (no daemon on iPad). Getting on-device
MLX to run took iOS-specific Metal/memory setup — see `docs/MLX_PROVIDER.md` "On-device (iPad)".
Deferred to step 8b: the eBird candidate list, subject isolation, and a small-model prompt variant
(FastVLM-0.5B echoes the prompt's placeholder keywords and over-applies species-ID instructions —
issues the larger Mac/OpenRouter models don't have).

## Next stages

- **MLX preset list pruning**: `AIModelSelection.presets`'s `mlx:` entries grew during exploratory
  accuracy testing (see `docs/MLX_PROVIDER.md`); expect to trim to whichever models actually proved
  worth keeping once testing settles.
- **Auto-skip-on-process** (`docs/SPEC.md` §5's "successfully processed files auto-skip from the
  current session view") is intentionally not wired up — the user prefers processed files staying
  visible for now; revisit only if asked.
- **iPadOS app**: source browse through process/move, `Timeline.json` GPS suggestion, reverse
  geocoding, and AI-assisted suggestions (MLX + OpenRouter, first cut) — steps 1-8 of the planned
  8-step checklist — are shipped and user-verified on the physical iPad (see "Status" above).
  Remaining: **step 8b** (eBird candidate list, subject isolation, and a small-model prompt variant
  for FastVLM-0.5B), and a not-yet-designed Mac-initiated pull to move processed files off the iPad's
  local staging folder.
