# MacPhotoMaster (Swift) — Feature Spec

Self-contained product spec. This describes *what* the app should do, adapted from a working
Python/PySide6 sibling project's completed feature set — not a line-by-line port. Swift-specific
architecture lives in `ARCHITECTURE.md`.

## Purpose

A macOS app for ingesting photos from an SD card: browse, edit EXIF/IPTC/XMP metadata, get
AI-assisted description/keyword suggestions, enrich GPS from a Google Timeline export, rename
deterministically, and copy files into local storage.

## Core working assumptions

- **Non-destructive SD card workflow.** Files are copied off the card, never deleted from it
  automatically. "Skip" hides a file from the current session view; it never deletes anything.
- **Trash, not delete.** Any user-initiated file removal goes through the system Trash (or an
  equivalent recoverable API), never a permanent delete.
- **Copy verification.** After copying a file to its destination, verify size + a strong checksum
  (SHA-256) before treating the source as safely handled.

## 1. Source browsing

- Folder tree + thumbnail grid for a source directory (SD card or any folder).
- Supported file types: `.jpg`, `.jpeg`, plus at least one RAW format (the reference app used
  Olympus/OM System `.orf`; pick based on whatever camera the Swift app's user actually shoots).
- Thumbnails and full preview load off the main thread; RAW files fall back to the embedded
  preview JPEG (extracted via `exiftool -b -PreviewImage`) when no faster path exists.
- **Capture-set grouping**: files are grouped by capture timestamp at second precision
  (`DateTimeOriginal`, falling back to `CreateDate`). A "Stacked" view mode shows one representative
  tile per group instead of every member.
  - Representative selection: prefer the first JPG/JPEG in filename order; else the first file.
    (Learned the hard way in the reference app: picking "largest file" biases toward heavily
    processed/filtered renders in in-camera bracket bursts — filename-order-first JPEG is a better
    proxy for "the plain render".)
- **Skip** removes a file (or a whole capture set) from the current session view only — persisted
  per source folder so a re-opened folder remembers what was skipped.
- Manual multi-select (cmd-click to toggle, shift-click for range) should act on the *full capture-group
  membership* of whatever's selected, not just the visibly selected representative tiles — otherwise
  bulk actions silently skip hidden group members (e.g. the RAW file behind a stacked JPEG).
- A row of every member of the currently active selection (a capture set's members, or a single
  image) shows under the large preview. Clicking a thumbnail there swaps which member is shown
  large; cmd-clicking toggles a finer-grained "ring-selection" within that row (e.g. exclude the RAW
  file from a set before processing). This ring-selection is a second, narrower level of multi-select
  than the grid's — see §5 for how it feeds process/move.

## 2. EXIF read and field mapping

- Read full metadata per file via `exiftool -j -G1 -a -s`.
- Map a defined subset to editable/display fields: title, description, keywords, camera make/model,
  lens type/model, aperture, shutter speed, focal length, focus distance, capture time (raw +
  display format), ISO, GPS lat/lon/altitude, and any in-camera filter/effect token the camera
  encodes (used later for auto-description rules and renaming).
- When reading more than one file (e.g. a card import), batch the reads into as few `exiftool`
  invocations as possible rather than spawning one process per file — see docs/ARCHITECTURE.md
  "exiftool integration" for the batching/fallback pattern.

## 3. Metadata write-back

- Idempotent keyword writes — re-saving must not duplicate existing keywords.
- Roll back cleanly if the underlying `exiftool` write fails partway.
- Save scopes: single file, or a full capture set (propagates the same edited fields to every
  member).
- When saving a capture set, files sharing identical write values (the common case: same
  description/keywords/GPS across the set) should be written in one batched `exiftool` invocation
  instead of one per file — see docs/ARCHITECTURE.md "exiftool integration". Files needing a
  unique per-file value (e.g. a rename-derived title during process/move) can't be grouped and
  stay one invocation per file.
- Field → tag mapping (dual-write EXIF/IPTC/XMP so both older and newer metadata consumers see it):
  - Title → `IPTC:ObjectName`, `XMP-dc:Title`
  - Description → `IPTC:Caption-Abstract`, `XMP-dc:Description`
  - Keywords → `IPTC:Keywords`, `XMP-dc:Subject`
  - GPS → `GPSLatitude`/`GPSLatitudeRef`, `GPSLongitude`/`GPSLongitudeRef`, optional
    `GPSAltitude`/`GPSAltitudeRef` — Ref tags derived from the value's sign so southern/western
    coordinates read back with the correct hemisphere.

## 4. Rename

- Deterministic pattern: `sequence_batch_YYYYMMDD_HHMM_[artfilter]_camera_lens.ext`.
- Sanitize for filesystem-safe characters; resolve collisions deterministically (never silently
  overwrite).
- `Batch` is a manual per-session label, not GPS-derived — GPS enrichment and renaming are
  deliberately decoupled.
- Title auto-populates from the filename stem as a starting point (still user-editable).

## 5. Process & move

- Scopes: single image, capture set, current (manual) selection, or the whole session.
  - "Current (manual) selection" prefers the preview filmstrip's ring-selection (§1) when the user
    has narrowed it to a proper subset; otherwise it falls back to the grid's multi-select, expanded
    to full capture-group membership. This lets the filmstrip's narrowing double as a process/move
    scope, not just a preview-picker.
- Copy-first — never deletes from the source (SD card).
- Destination routing by file type (example from the reference app; adapt paths to taste):
  - RAW → `<library>/<Month>/<DD>/`
  - JPEG → `<library>/<Month>/<DD>/jpg/`
- Verify copy (size + SHA-256) before marking source-safe.
- Successfully processed files auto-skip from the current session view.

## 6. AI-assisted suggestions

- Backend-agnostic: a small provider interface (think: local Ollama server vs. a cloud API like
  OpenRouter) behind one prompting/parsing layer. Adding a backend should mean writing one new
  provider, not touching prompt/parsing logic.
- Group-aware: one AI pass runs on the capture-set representative image; the user applies the
  resulting draft description/keywords to all group members at once.
- Prefer sending a RAW/unfiltered image to the AI over a heavily in-camera-filtered JPEG
  representative when both exist in a set — an Art-Filter-Bracket JPEG (monochrome, grainy, etc.)
  skews AI description/keyword output toward the filter effect rather than the actual scene.
- Vision-capability pre-check before sending an image request (don't send a vision request to a
  text-only model).
- Fallback chain for timeouts/empty responses: retry once with a cropped, lower-effort request
  before surfacing a failure to the user. Log request timing/payload size for diagnostics.
- Auto-applied metadata rules at save/process time (not shown live in the editable fields):
  e.g. a "straight out of camera" keyword on unedited JPEGs, and an appended note when an in-camera
  filter/effect was active.

## 7. GPS enrichment from Timeline export

- Source: a Google Timeline JSON export, imported idempotently into a local SQLite cache (via
  GRDB.swift — see `TimelineLocationCache`) keyed by a normalized record identity, so re-imports
  don't duplicate rows.
- Matching: nearest-timestamp lookup, but **only within a bounded window** (30 minutes in the
  reference app — tune based on real coverage density). No match within the window → leave GPS
  blank; never guess.
- Never overwrite GPS or altitude that already exists in a file's own EXIF — camera-recorded data
  always wins over inferred data.
- **Altitude is not trusted from phone-based Timeline data.** Phone GPS chips have poor vertical
  accuracy and WIFI/cell-based positioning has none; timeline `altitude` fields are frequently
  implausible (large fractions negative/underground in the reference app's data). Always leave
  altitude blank from timeline matching and separately look it up from a ground-elevation service
  (e.g. USGS EPQS) keyed by the applied lat/lon. Cache elevation lookups by rounded coordinate to
  avoid redundant network calls for capture sets shot at the same spot.

## 8. Privacy / repo hygiene

- Any Timeline export JSON and any local location-cache database must be gitignored — never commit
  real location history.
- No API keys or secrets committed; read from process environment.

## Deliberately out of scope (for now)

- Flickr/other upload pipelines — treat as a separate integration, not core scope.
- Anything the reference app hasn't shipped yet (see its own backlog) shouldn't be assumed as a
  requirement here — build the above first, then re-derive next steps from real usage.
