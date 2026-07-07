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
  vision-capable model, and/or an [OpenRouter](https://openrouter.ai) API key (read from the
  process environment — see `docs/SPEC.md` §6). A third, native in-process MLX backend
  (`mlx-swift-lm`, no server/API key needed) is also available — see `docs/MLX_PROVIDER.md`.
- Optional, for eBird-verified bird-species candidate lists in AI prompts: an
  [eBird](https://ebird.org) API key, read from the process environment as `EBIRD_API_KEY`. Note
  that a shell-exported value won't reach an Xcode/Dock-launched process — set it via Xcode's
  Product > Scheme > Edit Scheme > Run > Arguments > Environment Variables, or `launchctl setenv`.

## Getting started

Open `Package.swift` directly in Xcode, or from the command line:

```sh
swift build
swift run
swift test
```

`swift run` launches the app as a plain process (no `.app` bundle yet — no custom icon/Dock
identity, and no stable code-signing identity across rebuilds). That's fine for day-to-day
development, but it means macOS privacy grants (e.g. Files and Folders access to a Google Drive
folder for Timeline sync) tied to the ad-hoc signature can need re-granting after a rebuild.
Packaging as a proper signed `.app` is a later step.

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
  via `SubjectIsolationService` (crops to the Vision-detected subject before sending), and via an
  eBird region-species candidate list (see `EBirdCandidateFormatting`) that verified-locally-recorded
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

Not yet built: a packaged `.app` bundle with stable signing/entitlements, and the deferred items
noted in `CLAUDE.md` (ImageIO metadata write-back).

## Next stages

- **Metadata-panel restructure (planned as "Phase B", not started)**: the right-hand Metadata pane
  can't take the same translucent "sidebar" material or native collapse behavior the left Source
  pane gets for free, because `NavigationSplitView` only applies those to its leading column.
  Fixing either requires pulling `MetadataPanelView` out of the 3-column `NavigationSplitView` into
  a manually-managed panel (own width/visibility state, no free native behavior) — a real
  structural change to `ContentView`, not a toggle. Bundled with this: GitHub issue #6 ("Keywords
  block not right-aligned" — the keywords field's right margin doesn't reach the pane's right edge
  when the pane is widened; likely a `Form`/`LabeledContent` width-constraint quirk worth
  revisiting once the panel is restructured anyway). Higher-risk structural change — do this on a
  fresh feature branch per established project precedent (see `mlx-native-provider` in git
  history), not directly on `main`.
- **MLX preset list pruning**: `AIModelSelection.presets`'s `mlx:` entries grew during exploratory
  accuracy testing (see `docs/MLX_PROVIDER.md`); expect to trim to whichever models actually proved
  worth keeping once testing settles.
- **Auto-skip-on-process** (`docs/SPEC.md` §5's "successfully processed files auto-skip from the
  current session view") is intentionally not wired up — the user prefers processed files staying
  visible for now; revisit only if asked.
