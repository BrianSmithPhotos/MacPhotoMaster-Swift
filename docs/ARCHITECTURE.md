# Architecture

Swift/SwiftUI equivalent of the reference app's `ui/` + `services/` + `workers/` split. See
`SPEC.md` for what the app does; this is about where code should live.

## Layers

- **`Sources/MacPhotoMaster/Views/`** — SwiftUI views. Layout and bindings only, no business logic.
  Equivalent to the reference app's `ui/widgets/`.
- **`Sources/MacPhotoMaster/ViewModels/`** — `@MainActor` `ObservableObject` (or `@Observable`)
  types that hold UI state and call into services, usually via `Task { }`. Equivalent to the
  reference app's `ui/main_window.py` orchestration plus its `workers/` — Swift's structured
  concurrency (`async`/`await`, `Task`) replaces the need for a separate `QRunnable`-style worker
  layer. A view model kicks off an `async` service call in a `Task`, the service does its I/O off
  the main actor, and the result flows back to `@Published` state.
- **`Sources/MacPhotoMaster/Services/`** — the actual logic: exiftool invocation, capture grouping,
  renaming, AI provider calls, timeline/elevation/geocode lookups. Same role as the reference app's
  `services/`: no Qt/SwiftUI imports, easy to unit test in isolation. Prefer plain `struct`s/
  `actor`s with `async` functions over classes with mutable state where possible.
- **`Sources/MacPhotoMaster/Models/`** — plain data types (`PhotoAsset`, `CaptureSet`, etc.),
  `Codable` where they cross a process/network boundary (Timeline JSON, AI provider responses).

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

## Provider pattern (AI)

Mirror the reference app's split: a small `AIProvider` protocol (async chat/vision call, given an
image + prompt, returning parsed suggestions) with concrete implementations per backend (e.g. an
Ollama-backed local provider, an OpenRouter-backed cloud provider). Prompting and response-parsing
logic lives in one shared place and stays backend-agnostic; adding a backend means adding one new
type conforming to `AIProvider`.

## File safety

- Deleting a file goes through `NSWorkspace.shared.recycle(_:completionHandler:)` (or
  `FileManager.trashItem`), never `FileManager.removeItem`.
- Verify a copy (size + SHA-256, `CryptoKit.SHA256`) before treating a source file as safely
  handled — see `SPEC.md` §5.

## Testing

Favor testing the `Services/` and `Models/` layers directly (pure logic, no UI) — this is where the
reference app's test suite concentrates its coverage (see its `docs/TESTING.md` for the shape of
what's worth covering: field-mapping, grouping decisions, rename pattern generation, destination
routing, JSON/response parsing, coordinate/timestamp matching — not widget wiring).
