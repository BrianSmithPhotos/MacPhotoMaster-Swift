# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

MacPhotoMaster (Swift): a from-scratch Swift/SwiftUI reimplementation of the Python/PySide6
sibling app [`phototags`](https://github.com/BrianSmithPhotos/phototags) — taken on as a way to
learn Swift and SwiftUI, not a line-by-line port. Read `docs/SPEC.md` (what the app should do) and
`docs/ARCHITECTURE.md` (where code should live) before starting work — both are self-contained; you
don't need the Python repo open to work here, though it's useful as a reference implementation to
compare against for logic that's being ported (e.g. Timeline JSON parsing, GPS matching).

## Stack & Tooling

- macOS 14+, Swift 5.10, SwiftUI. `swift build` / `swift run` / `swift test` from the repo root, or
  open `Package.swift` directly in Xcode.
- `exiftool` on `PATH` (`brew install exiftool`) — all metadata read/write goes through it via
  `Process`, same as the Python sibling app. See `ExifToolClient` and `docs/ARCHITECTURE.md`
  "exiftool integration" for the batching/PATH-resolution pattern.
- `NativeMetadataReader` (ImageIO-based) is a separate, read-only prototype for EXIF/IPTC/GPS
  metadata and RAW previews without shelling out — see its header doc for the known gap (no
  manufacturer maker-note fields, e.g. Olympus `ArtFilterEffect`). Not yet wired into the app; not a
  replacement for `ExifToolClient`'s write path.
- **GRDB.swift** for local SQLite (the Timeline GPS cache) — chosen over SwiftData because the
  nearest-timestamp/bounded-window/tie-break query doesn't map cleanly onto `#Predicate` macros. See
  `docs/ARCHITECTURE.md` "Local cache (Timeline GPS matching)" for the rationale. Default to GRDB +
  raw SQL for any future local-cache work in this repo rather than reaching for SwiftData.
- Background/I/O work uses Swift structured concurrency (`async`/`await`, actors) — no `QThreadPool`
  equivalent needed; see `docs/ARCHITECTURE.md` "Concurrency rules".

## Architecture

`Views/` (SwiftUI, no logic) → `ViewModels/` (`@MainActor`, holds state, calls services from a
`Task`) → `Services/` (the actual logic, `async`, no UI imports) → `Models/` (plain data types).
Full detail in `docs/ARCHITECTURE.md`.

## Coding Style

- Swift 5.10, type-annotated where inference doesn't already make it obvious.
- Keep functions small and single-purpose. No speculative abstractions, no defensive code for cases
  that can't happen — three similar lines beat a premature helper.
- Doc comments only where the *why* isn't obvious from the signature (e.g. a documented scope gap or
  a non-obvious external-format quirk) — not on every function.
- No emojis, anywhere, ever.
- When debugging, find the root cause before changing code — don't guess-and-check.

## Deliberately deferred scope

- **Metadata write-back via ImageIO** (`NativeMetadataReader` is read-only by design) and **MLX
  integration for local AI inference** are both explicitly deferred — don't start on either without
  the user asking directly. Current AI-provider plan is Ollama (see "Hardware & model notes" below);
  MLX may become relevant later if Apple ships an "M5 Ultra" or similar high-bandwidth part.
- Anything in the Python sibling app's backlog that hasn't shipped there yet shouldn't be assumed as
  a requirement here (see `docs/SPEC.md` "Deliberately out of scope").

## Hardware & model notes

User's dev machine is a Mac Studio **M1 Ultra, 128GB unified memory** — not the latest Apple
Silicon, but memory bandwidth (819 GB/s) still beats the M5 generation (base M5: 154 GB/s; M5 Max
best config: up to 614 GB/s) for sustained local-LLM token generation, which is bandwidth-bound
rather than compute-bound. Decision: stay on this hardware and on **Ollama** (which added an MLX
backend on Apple Silicon as of v0.19, March 2026) rather than upgrading, until Apple ships something
like an "M5 Ultra" with bandwidth clearly ahead of the M1 Ultra.

## File Safety

- Deleting a file goes through `NSWorkspace.shared.recycle(_:completionHandler:)` or
  `FileManager.trashItem`, never `FileManager.removeItem`.
- Verify a copy (size + SHA-256 via `CryptoKit`) before treating a source file as safely handled —
  see `docs/SPEC.md` §5.

## Secrets & Privacy

- `Timeline*.json` and `*.sqlite`/`*.sqlite3` are gitignored — never remove that ignore or commit a
  real Timeline export or the location cache database (see `docs/SPEC.md` §8). Tests that need
  Timeline-shaped JSON use inline literals with fabricated coordinates/timestamps, never real
  exported data — see `TimelineImportParserTests.swift` for the pattern.
- No API keys or secrets committed; read from process environment.
