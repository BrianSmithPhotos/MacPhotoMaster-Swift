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
- Save scopes: single file, a full capture set, or the current manual selection (propagates the
  same edited fields to every member of every selected capture set — see §5's `.manualSelection`
  scope, which this reuses).
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
- **iPad divergence:** no `exiftool`, so there's no in-place write at all — `NativeMetadataWriter`
  always writes a `.xmp` sidecar instead (see its doc comment), and on iPad that sidecar is staged in
  local app storage, never on the camera/card itself, keyed by original filename + size rather than
  path. The sidecar only reaches the original file's actual tags later, via
  `ExifToolClient.foldInSidecarIfPresent(for:)` once the file (copied at Process & Move, below) is on
  a Mac. See docs/ARCHITECTURE.md "iPad file access & sidecar staging" for the reasoning.

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
- **iPad divergence:** the destination library is a fixed local folder inside the app's own sandbox
  (`Documents/ProcessedLibrary`), not user-picked — a Google-Drive-mounted destination was considered
  and ruled out (Drive's background sync could race with the copy+SHA-256 verify above). Getting
  processed files off the iPad afterward is a separate, not-yet-designed Mac-initiated pull, not part
  of Process & Move itself. See docs/ARCHITECTURE.md "iPad file access & sidecar staging".

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
- Location context: once a capture set has GPS (embedded or Timeline-suggested), reverse-geocode it
  to city/county/state, add those as keywords, and pass them to the AI prompt as scene context (helps
  with plausible local wildlife/plant identification) — see §7.
- Beyond the reference app: an eBird region-species candidate list (verified actually recorded near
  the photo's GPS fix) is added to the prompt for bird identification, and an optional, user-toggled
  "Crop to Subject" crop is sent instead of the full frame when a subject is detected — both added to
  reduce species-ID fabrication on small/distant subjects. The crop toggle defaults off and is a
  deliberate per-session choice (Toggle next to the AI model picker in the Metadata panel), not
  automatic: on a general scene (e.g. a street shot) it can isolate an incidental foreground object —
  a parked car, a lamp-post — instead of the scene the user meant to describe, so it's meant to be
  switched on only for close, small/distant subjects (birds, flowers, or otherwise). Turning the
  toggle on (or switching photos while it's already on) immediately computes and shows the crop —
  it no longer waits for a Suggest click. The crop itself is `SubjectIsolationService`'s AI pick by
  default, but the user can click-drag a rectangle on the big preview (`PreviewPanelView`) to
  override it; a plain click, or the "Reset to AI Crop" button next to the toggle, reverts to the AI
  crop. See `docs/ARCHITECTURE.md` "eBird species-list cache".
- **iPad divergence:** two providers only — native on-device MLX (`mlx:`) and OpenRouter
  (`openrouter:`); Ollama's daemon can't run on iPad. The AI image is sent full-frame (subject
  isolation is the one remaining deferred 8b item). On-device MLX needs the Metal/memory setup in
  `docs/MLX_PROVIDER.md` ("On-device (iPad)"); the recommended/default on-device model is
  **gemma-3-4b** (good keywords + descriptions in seconds). Small models (FastVLM-0.5B) use a
  `.compact` prompt profile — no copyable JSON keyword example, and species-ID instructions gated on
  the on-device scene-triage category — selected per-model (`PhotoBrowserViewModel.compactPromptModels`,
  toggled in Settings); larger models keep the full prompt. OpenRouter + eBird API keys are entered in
  the iPad Settings sheet (Keychain via `APIKeyStore`), since shell env vars don't reach an installed app.
- **iPad eBird divergence (binomial via local lookup):** the eBird candidate list is wired in, but the
  iPad sends **common names only** (halves the prompt for the small model) and, since small models don't
  reliably reproduce a Latin binomial (they omitted it, or on a stuck ID grabbed the alphabetically-first
  candidate), attaches the scientific name itself via a deterministic lookup after the response
  (`EBirdCandidateFormatting.attachScientificNames`). That lookup is deliberately conservative: whole-word
  matching (a wrong-binomial guard — substring matching once turned an egret into *Branta bernicla*),
  matches only the description + the user's own trusted keywords (never the model's fresh keywords, which
  can contain a hallucinated candidate), and only for an exact common name (a hedged "possibly a screech
  owl" gets no binomial — a safe miss). The prompt also tells small models to describe a bird generally
  rather than force a species when unsure.

## 7. GPS enrichment from Timeline export

- Source: a Google Timeline JSON export, synced down from Google Drive and imported idempotently
  into a local SQLite cache (via GRDB.swift — see `TimelineLocationCache`) keyed by a normalized
  record identity, so re-imports don't duplicate rows. The sync/import check runs on app launch,
  on every folder open/navigate, and on demand via the "Refresh Timeline" button, so a
  `Timeline.json` replaced mid-session is picked up without relaunching.
- **iPad divergence:** Google Drive Desktop's mounted filesystem path isn't available on iOS, so
  there's no automatic glob/copy-down (`TimelineDriveSync` is macOS-only). Instead the user locates
  `Timeline.json` once through the Files document picker (Drive registers as a Files provider) and
  the app persists a security-scoped bookmark, re-importing from it on launch/folder-load exactly
  like the Mac's sync check. GPS suggestions are also applied read-only (no editable lat/long
  fields), straight onto the asset, since the iPad metadata panel has no GPS text fields.
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
- Reverse geocoding: once GPS is set (embedded or Timeline-suggested), look up city/county/state
  (via OpenStreetMap Nominatim) once per capture set per session, merge the non-blank fields into the
  keyword edit buffer, and keep the result available as AI prompt context (§6).

## 8. Privacy / repo hygiene

- Any Timeline export JSON and any local location-cache database must be gitignored — never commit
  real location history.
- No API keys or secrets committed; read from process environment.

## Deliberately out of scope (for now)

- Flickr/other upload pipelines — treat as a separate integration, not core scope.
- Anything the reference app hasn't shipped yet (see its own backlog) shouldn't be assumed as a
  requirement here — build the above first, then re-derive next steps from real usage.
