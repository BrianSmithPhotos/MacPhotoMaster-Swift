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
- The large preview always follows the multi-selection. On Mac it shows the tile just clicked, since
  a modifier-click is still a click on a specific photo. On iPad, where Select mode makes a tap a
  toggle rather than a pick, it shows the selection's **earliest member in grid order**: picking the
  same tiles in any order previews the same photo, and extending a selection doesn't yank the preview
  away from what you were already looking at.
- A row of every member of the currently active selection (a capture set's members, or a single
  image) shows under the large preview. Clicking a thumbnail there swaps which member is shown
  large; cmd-clicking toggles a finer-grained "ring-selection" within that row (e.g. exclude the RAW
  file from a set before processing). This ring-selection is a second, narrower level of multi-select
  than the grid's — see §5 for how it feeds process/move.
- iPad shows the previewed file's **Title** — the live rename preview (§4), batch label included,
  not the current filename — above the preview. A set's JPEG and RAW look identical at preview size,
  and the filmstrip is otherwise guesswork.
- **Preview zoom** (the reference app had this as a slider; here it's pointer/touch-driven):
  - Mac: scroll wheel over the large preview zooms, anchored at the pointer — the image point under
    the cursor stays under the cursor. Trackpad pinch does the same thing.
  - iPad: pinch to zoom, drag to pan, double-tap to toggle between Fit and 300%.
  - Range is **Fit to 8x Fit**. Fit is the hard minimum: the preview can never be zoomed *out* past
    the whole frame, so anything not visible at Fit is genuinely not in the file.
  - Scrollers appear on each axis once the scaled image exceeds the pane. Dragging pans.
  - The current scale is **always** displayed ("Fit", "240%"), not just while zoomed. This is the
    point of the feature as much as inspection is: a zoomed-in preview and a differently-framed
    source file look identical, and §6's AI suggestions read from a *different file* than the
    preview shows, so an un-signposted zoom state makes a correct AI description look like a
    hallucination. Tapping/clicking the readout returns to Fit, as does ⌘0 (Mac) or a double-click/
    double-tap.
  - **Zoom and position persist across a selection change** (Mac): switching between a RAW and its
    developed JPEG, or between frames in a burst, is a comparison, so the next photo opens at the
    same scale showing the same part of the frame. The position is held as a fraction of the image,
    not in pixels, so it survives two previews of different sizes.
  - **Disabled while subject-isolation crop mode is on** (§6), on both Mac and iPad. That mode owns
    the drag gesture for drawing the crop rectangle (and, on iPad, tap-to-pick) and maps view
    coordinates to image pixels assuming an unzoomed `.fit` layout; supporting both would mean
    composing the zoom transform into that mapping for no real gain. Turning crop mode on resets the
    preview to Fit; the zoom control is inert (Mac) or hidden (iPad) until it's turned off again.
  - Zoom reads the same 2048px-cap decode the preview already loads, so past roughly 100% of that
    it is soft rather than more detailed. Re-decoding at a higher cap when zoomed in is deferred.
- **Camera-look visualiser** (⌘L, off by default). A translucent strip over the preview showing the
  in-camera creative settings as a graphic rather than as the sentence §3 writes to `Instructions`.
  Shipped 2026-08-10, covering element groups 1 and 2 of the plan under "Ideas, not started"; groups
  3 to 6 (tone curve, sliders, finish, provenance) are still outstanding.
  - One hero graphic per look, which works because the colour-rendering modes are mutually
    exclusive: a twelve-spoke saturation disc for a Colour Profile, a 30-stop ring for Colour
    Creator, an 18-stop banded ring for Partial Color, a filter/tint circle for monochrome. A mode
    carrying no readings shows its name alone.
  - A RAW file shows "Neutral rendered RAW" rather than the look. The creative settings are the
    camera's JPEG rendering; the ORF carries the same maker-note bytes but isn't developed through
    them, so displaying them against it would claim something untrue about the file on screen. Same
    reasoning gates the `Instructions` write in §3.
  - The Colour Profile disc carries each spoke's value twice — as a radius from the zero circle and
    as that hue's saturation — because a hue slider *is* a saturation control for its band. Colour
    outside the figure is muted rather than dropped, so the shape reads as the balance actually
    dialled in against the whole wheel. Values interpolate in angle between the measured spoke
    centres rather than stepping twelve ways, since those centres are unevenly spaced.
  - Anchored to the **photo's** top-right corner, not the pane's, so it stays on the picture as the
    side panes are resized instead of drifting into the letterbox margin. See
    docs/ARCHITECTURE.md "Preview overlays and where the photo actually is" — the rectangle has to
    come from the scroll view, and cannot be recomputed from the SwiftUI container's size.

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
  - Description → `IPTC:Caption-Abstract`, `XMP-dc:Description`,
    `XMP-iptcCore:AltTextAccessibility` (the IPTC 2021.1 accessibility field — same text, since the
    description already *is* a description of the image; Lightroom Classic 12.3+ surfaces it, and
    WordPress plugins read it to fill the alt attribute. `ExtDescrAccessibility` is deliberately not
    written: it's for a longer description of a complex image and there's no separate source for it)
  - Keywords → `IPTC:Keywords`, `XMP-dc:Subject`
  - GPS → `GPSLatitude`/`GPSLatitudeRef`, `GPSLongitude`/`GPSLongitudeRef`, optional
    `GPSAltitude`/`GPSAltitudeRef` — Ref tags derived from the value's sign so southern/western
    coordinates read back with the correct hemisphere.
  - Focus distance → `EXIF:SubjectDistance` (metres) + `XMP-exif:SubjectDistance`. The app reads
    focus distance for display from the Olympus `FocusDistance` MakerNote, which other apps
    (Lightroom, Photo Mechanic, DxO) don't surface; copying it into the standard SubjectDistance tag
    on write makes it visible downstream. Per-file-unique like Title, so it rides the single-file
    write path only (never the batched overload), and is written only when the MakerNote yields a
    usable finite positive distance — a blank field, an "inf" reading, or `0` writes nothing.
  - Camera look → `IPTC:SpecialInstructions` + `XMP-photoshop:Instructions`. The in-camera
    creative-dial settings (profile hue sliders, Colour Creator colour/strength, mono filter, grain,
    shading, tone curve, the profile's own contrast/sharpness/saturation, the art filter with its
    effect/partial-colour/B&W-filter/tint options, and the plain picture modes with their sliders,
    `PictureModeEffect` and `Gradation`) as one readable string
    built by `CameraLookParsing`, with every value left
    at its default suppressed so ordinary frames get no write at all. Only Natural with nothing
    dialled is silent — Muted, Monotone, Underwater and i-Enhance are distinct renderings and are
    recorded even when untouched. B&W filter and tint can arrive by three mutually exclusive routes
    (monochrome profile, Monotone picture mode, art filter), each with its own tag and its own value
    numbering, so they are never read through a shared table. The Partial Color filter's ring
    position is reported as a colour name rather than the bare index exiftool gives, from a table
    measured by shooting a hue wheel at all eighteen stops: stop 0 is yellow and each stop steps
    20 degrees down in hue. Instructions is the
    destination because a probe of six candidate fields found it one of only four DxO PhotoLab
    surfaces, and the only one of those not already used. Legacy IPTC IIM caps SpecialInstructions
    at 256 characters where XMP has none, so the IIM half is truncated and the XMP half always
    carries the full string. Per-file-unique like Title, so single-file write path only.
    Read from the JPEG, which is where the applied look lives — the ORF deliberately stays at the
    neutral mode-dial value so a later RAW edit isn't pre-committed to the in-camera rendering.
    The camera's `*` "profile has been edited" indicator is not recoverable: it compares against the
    slot's saved baseline, and the file only carries current values. The values make it redundant.
- **iPad divergence:** no `exiftool`, so there's no in-place write at all — `NativeMetadataWriter`
  always writes a `.xmp` sidecar instead (see its doc comment), and on iPad that sidecar is staged in
  local app storage, never on the camera/card itself, keyed by original filename + size rather than
  path. The sidecar only reaches the original file's actual tags later, via
  `ExifToolClient.foldInSidecarIfPresent(for:)` once the file (copied at Process & Move, below) is on
  a Mac. See docs/ARCHITECTURE.md "iPad file access & sidecar staging" for the reasoning.
  Focus distance is a further casualty of the missing MakerNote reader: the iPad can't read it at
  all, so nothing lands in `SubjectDistance` there — it's recovered and written during the Mac-side
  import (`IPadImportService`), which reads the Olympus MakerNote via exiftool. The camera look is a
  casualty of the same gap and is recovered the same way.

## 4. Rename

- Deterministic pattern: `sequence_batch_YYYYMMDD_HHMM_[artfilter]_camera_lens.ext`.
- The `[artfilter]` segment covers every deliberately-chosen look, not just Art Filters: an active
  Art Filter effect wins, else a creative-dial `PictureMode` (`Color Profile 1-4`, `Monochrome
  Profile 1-4`, `Color Creator`), else a stacked-image state, else multiple exposure. Plain
  mode-dial looks (Natural, Vivid, Portrait...) get no segment — they aren't a chosen look.
  Note `PictureMode` 17 prints as "Art Mode" but is Colour Profile 4 on the OM-3, and is remapped.
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
- The copy lands under a hidden staging name and is renamed to its real name only after the metadata
  write succeeds, so the file never exists at its final name in a half-annotated state. Without this,
  anything watching the library folder can index it in the gap and cache it: DxO PhotoLab was
  observed doing so and then showing empty Title and Instructions (the only two fields not already
  present on the source) long after the correct values were on disk. Any XMP sidecar produced by the
  write is renamed alongside it, since `foldInSidecarIfPresent` matches on basename.
- Successfully processed files auto-skip from the current session view.
- **iPad divergence:** the destination library is a fixed local folder inside the app's own sandbox
  (`Documents/ProcessedLibrary`), not user-picked — a Google-Drive-mounted destination was considered
  and ruled out (Drive's background sync could race with the copy+SHA-256 verify above). See
  docs/ARCHITECTURE.md "iPad file access & sidecar staging".
- **Finishing iPad-processed files on the Mac.** An iPad-processed file is only half done: with no
  `exiftool` there, the in-camera art filter reaches neither the filename nor the keywords, and
  description/keywords/GPS live only in the `.xmp` sidecar beside each image. The Mac app's "Import
  from iPad" sheet completes them, as a batch with no review step (reviewing already happened on the
  iPad).
  - **Transport is manual and out of scope.** The import takes any local folder; how the bytes got
    there is not the app's concern. Two routes work: dragging `ProcessedLibrary` out of Finder's
    Files tab over USB, or sending it from the iPad's Files app to an SMB share hosted on the Mac.
    Neither clears the iPad copy — Files downgrades a cross-provider transfer to a copy even when
    Move is chosen — so deleting the source on the iPad is always a separate manual step. Prefer a
    Mac-hosted share over a NAS: the files then land on local disk, where the import's `trashItem`
    cleanup works (it routinely fails on network volumes, which have no `.Trashes`) and the SHA-256
    verify isn't reading every RAW back over the network. iCloud is ruled out for the same reason as
    Google Drive above: lazily materialized placeholders race with the SHA-256 verify.
  - Per file: read the maker notes with `exiftool` for the art-filter token, read the sidecar back,
    rebuild the filename (identical to the iPad's, plus the art-filter segment — both apps derive
    camera/lens/capturedAt from the same reader, so there's no naming drift), and re-run the ordinary
    Process & Move above with the exiftool writer. That write of title/description/keywords/GPS into
    the destination copy *is* the sidecar being folded into the image, and the standard auto-metadata
    rules (§6) are what put the art filter into the keywords and the "In camera effect" note into the
    description.
  - Source image and sidecar are trashed only after the destination copy verifies, then emptied
    directories are pruned up to (never including) the picked folder. A partially failed run is
    therefore safe to re-run over the same folder — it only sees what was left behind.
  - A file whose sidecar is missing or unreadable, or whose name this app didn't generate, is
    **skipped and named in the failure list**, left untouched. Importing it bare would silently
    discard the iPad session's descriptions, keywords and GPS.

### RAW develop

Right-click a capture set (or a RAW in the preview filmstrip) → **Develop RAW** renders that RAW to a
JPEG variant with Apple's RAW engine and joins it to the capture set as an ordinary member, editable,
saveable and processable like any other file. It is not a develop UI: the render is at the filter's
default settings, the point being Apple's engine applied to the file as the camera recorded it.

- **Decoder routing**, checked per file, because decoder support is per *camera model*, not per
  format:
  1. the file's own `supportedDecoderVersions` contains `9` → decode direct at v9;
  2. else, if Adobe DNG Converter is installed → convert to DNG in a temp directory and decode that
     at `9.dng` (the DNG pipeline is model-agnostic, which makes this the general answer for an
     unsupported body);
  3. else → decode at the newest version the file itself offers.
  No maintenance is needed when a body joins the decoder-9 list — it simply starts taking branch 1.
- **Naming**: the decoder that actually ran goes in the filename's art-filter slot and the keywords
  as `RAW9`/`RAW8` (§4). It is decoder-honest, not aspirational: a file that had to fall back reads
  `RAW8`. A developed file never gets the `sooc` keyword, and never gets the "In camera effect"
  description note — a RAW carries no in-camera effect.
- **Storage**: the derivative is staged in Application Support, never written to the SD card (which
  may be full, and stays in use across a multi-day trip — the same reasoning as the iPad's sidecar
  staging). It is trashed once Process & Move has verified it into the library.
- **iPad divergence**: iPadOS cannot write a DNG (ImageIO lists no DNG output type), so a body
  outside the decoder-9 list cannot be developed there at all. The iPad instead offers **Mark for RAW
  develop**, which stages a marker keyword in the sidecar and badges the tile; the marker rides
  Process & Move into the destination `.xmp`, and the Mac's "Import from iPad" develops the file and
  strips the marker. The marker is never shown in the keyword field and never reaches the library
  copy's keywords.
  - A develop failure at import time is reported but does not fail the import: the RAW itself is
    already verified into the library by then.

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
  default, but the user can override it on the big preview (`PreviewPanelView`): on the Mac by
  click-dragging a rectangle (a plain click, or the "Reset to AI Crop" button, reverts to the AI
  pick); on iPad the same drag-to-box works and a **tap** additionally picks whichever detected
  subject is under the finger (`SubjectIsolationService.subjectInstanceRect`), so a touch can choose
  between several subjects — the "Reset to Auto Crop" button reverts. See `docs/ARCHITECTURE.md`
  "eBird species-list cache".
- **iPad divergence:** two providers only — native on-device MLX (`mlx:`) and OpenRouter
  (`openrouter:`); Ollama's daemon can't run on iPad. Subject isolation ("Crop to Subject") now
  works on iPad too — the toggle lives in the metadata sheet, and the big preview swaps its zoomable
  scroll view for a static Fit canvas whose overlay takes a drag-to-box crop or a tap-to-pick subject
  (see the "Crop to Subject" bullet above); off, the AI image is sent full-frame. On-device MLX needs
  the Metal/memory setup in
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

## Ideas, not started

In priority order — the rest of the visualiser first.

- **Camera-look visualiser, groups 3 to 6.** Groups 1 and 2 shipped 2026-08-10 (§1); what remains is
  everything below the hero graphic, and the **tone curve is next**. Unlike group 2 this needs
  design decisions before code: whether `ToneLevel`'s highlight/mid/shadow are one spline or three
  independent pivots, and where each pivot sits on the curve and how far along it each one reaches.
  Expect that to need measuring off real frames the way the three rings were, rather than being
  readable off the maker-note alone.

  How `Gradation` composes with them is **not** among those questions, as of 2026-08-10: it cannot,
  because the two never coexist. Gradation belongs to the standard picture modes and the
  highlight/mid/shadow curve to the Color and Monochrome Profile modes, so no frame carries both,
  while contrast sits on top of either. The composite is therefore always one tonal control composed
  with contrast — a much smaller thing to draw than a gradation preset stacked on three tone axes.

  **Corrected 2026-08-11 by group D** (`scripts/README.md` "Groups D and E measured"). "Contrast
  sits on top of either" is wrong, and measurably so: when `Gradation` is anything but Normal the
  camera **ignores** `PictureModeContrast` completely. High Key contrast 0 against High Key contrast
  +2 is the identity curve to 1.2 levels, while the same dial change under Normal moves 20.2. The
  maker note still records the ignored value, so **the view must suppress contrast whenever
  `Gradation != Normal`** rather than trusting the field — drawing it would show a 20-level bend the
  photograph never received. This makes the graphic simpler, not harder: with a gradation preset set,
  the composite *is* the gradation curve.

  **Also answered 2026-08-11 by group E: the tone curve and contrast are mode-independent, so the
  app stores one table, not one per picture mode.** Monochrome Profile and Color Profile render
  Midtone +7 within 0.1 of a level of each other and Shadow -7 within 0.0; Natural and Color Profile
  render Contrast +2 within 0.2. All are far inside the rig's ~2-level cross-run repeatability.

  **Decided 2026-08-10, before shooting.** Draw **one composite result curve**, not the camera's and
  OM Workspace's two (Highlight-and-Shadow on one, Midtone on a second). That split is a grouping
  artefact of their editing UI: it shows what was dialled in rather than what came out, which is the
  opposite of what this overlay is for. Workspace is also not a reference for the shape — it offers
  a -10 Shadow the camera's own ±7 range cannot express, so what it draws is its own developer's
  rendering, not the camera's. **Contrast folds into that curve too** and therefore moves from group
  4 to group 3, leaving sharpness and saturation as the sliders. **High Key and Low Key are drawn as
  measured curves in their own right** — not folded in with the tone sliders, since they never
  appear alongside them. **Auto cannot be drawn at all**: it is a scene-adaptive local operator with
  no single curve to find, so it stays the flag the parser already makes it (`gradationIsAuto`) and
  the view names it rather than drawing it.

  **The curve is the result; the values are what you dial.** Those are two different questions and
  the graphic should answer both. Reading an existing image, what matters is the tone response the
  frame actually got — so the curve is the composite, with the individual settings not separately
  visible in it. But wanting that look *again* means needing the numbers to set on the camera, which
  the composite by construction cannot show. So the drawn curve carries its originating values
  alongside it, revealed on hover rather than shown permanently: the settings are the secondary
  question, and printing five numbers over a 220pt strip would crowd out the shape. Same argument as
  the disc in §1 — draw the result, keep the reading available.

  Measurement tooling and the ~41-frame shot list are written — see
  `scripts/README.md` "make-tone-ramp.py and measure-tone-curve.py". The decisive experiment is
  first in that list: whether the pivots compose independently, which decides whether this is three
  measured basis curves or a grid. Because each tonal control lives in its own picture mode, the
  shot list carries a separate reference frame per mode, and it also asks whether contrast and the
  tone curve mean the same thing across modes — which decides whether the app stores one table or
  several.

  **Answered 2026-08-11 by group A** (`scripts/README.md` "Group A measured"). Contrast composes
  with Highlight serially and independently — 0.46 rms against a 3-level threshold — so Picture Mode
  contrast is a **separate stage** applied over the tone-level curve, not part of the same basis.
  The three tone levels do **not** compose independently: additive offset is the best of the three
  models tested but is wrong by up to about 8 levels in the upper midtones.

  **Decided: compose the tone levels additively and accept that error.** Eight levels is about 3
  percent of the range on a 220pt strip whose job is to show the shape of what the camera did — it
  does not change which way the curve bends or where it pivots, which is the whole content of the
  graphic. So this stays three measured basis curves plus a contrast stage; it does not become a
  grid. The alternative was ~30 more frames to tabulate combinations the viewer cannot see.

  That is a decision about *this* use case, not a claim that the interaction is uninteresting. If
  the composition itself is ever worth studying — how a camera's tone controls really combine is a
  fair question in its own right — the cheapest next probe is the same pairs at intermediate
  strengths (H+4 & S−4 against H+7 & S−7) to see whether the residual scales with the applied
  displacement. That separates a modellable effect from one that would have to be tabulated, for
  four frames. Group A's residuals are suggestive but three points cannot fit anything: at input 128
  they agree at +4.60, +4.58 and +4.60, and the two pairs involving Midtone track each other within
  0.6 of a level, with the Midtone-free pair the odd one out.

  The groups below are the original plan. They held up in implementation, so they stand as written
  for the remaining work.

  `Tests/MacPhotoMasterTests/Fixtures/CameraLookFixture.json` holds
  154 frames shot 2026-08-07 to 2026-08-09, one per distinct maker-note signature, giving 146
  distinct look strings with every branch of the parser represented by at least one real frame.
  The longest is 111 characters, comfortably inside the 256-character IPTC IIM cap.

  **Prerequisite: done, 2026-08-09.** `look(from:)` used to parse and format in a single pass, so
  the typed values existed only as locals inside the segment builders and a view would have had to
  re-parse this app's own output to draw a wheel. `CameraLookParsing.parse(from:)` now returns a
  `CameraLook` value type and `look(from:)` is `parse(from:)?.summary ?? ""`. The fixture is what
  made the refactor provable: `CameraLookFixtureTests` agreed byte-for-byte on all 154 frames
  across the change. A view can now read `hueSliders`, `toneLevels`, `colorCreator` and the rest as
  values, and `isModeOnly` distinguishes a bare mode name from a look carrying readings.

  Element groups, by what varies together rather than by which tag supplied it:
  1. **Identity** — mode/profile name. Exactly one, always present, and it selects group 2. *Done.*
  2. **Colour rendering** — the hero graphic, and the only *mutually exclusive* group: 12-spoke
     profile wheel, 30-stop Colour Creator ring, 18-stop Partial Color ring, monochrome filter and
     tint, or nothing at all. That exclusivity is what makes one large graphic viable rather than a
     stack of widgets. *Done*, though the profile wheel became a saturation disc rather than a ring
     — see §1 for why radius and saturation both carry the value.
  3. **Tonal response** — `ToneLevel`, `Gradation`, `PictureModeEffect` and contrast all bend the
     same curve, so they compose into one drawn curve rather than sitting beside each other.
  4. **Sliders** — sharpness and saturation. Contrast started here and moved to group 3 (above): it
     reads like a slider in the menu, but it is a tone curve, and drawing it apart from the other
     tone controls would misrepresent the result.
  5. **Finish** — grain, vignetting, the stacked art-filter `fx` records.
  6. **Provenance** — which B&W route supplied filter/tint, and the ORF/JPEG divergence.
     Diagnostic; collapsed by default.

  Two things fall out of the groups. B&W filter and tint reach group 2 by three mutually exclusive
  routes with three different numberings, and the parser must keep those strictly apart — but they
  mean the same thing to the eye, so the view should merge them: the separation is a file-format
  concern, not a display concern. And the three rings share one geometry — a hue circle with the
  measured stop positions marked — so the ring itself is one component.

  What they do *not* share is arity, and `CameraLook` already shows it: `hueSliders` is twelve
  simultaneous values, one per spoke, while `partialColor` and `colorCreator` are each a single
  selected stop. So the ring takes one of two value renderers — a per-spoke magnitude around the
  circle, or a marker plus its band — rather than being parameterised by stop count alone.

  All three rings are now measured off real frames (2026-08-09) — see `scripts/README.md` under
  `make-hue-wheel.py`. Two results bear directly on how to draw them. The twelve Colour Profile
  spokes are *not* evenly spaced: gaps run 11.7 to 44.1 degrees, spaced perceptually rather than
  geometrically, so the wheel wants the measured centres and not twelve at 30. And Partial Color has
  a real band to draw rather than a marker: types I and III share a 62-70 degree band and differ
  only at the shoulders (III's 90-to-10% edge is 4-14 degrees against I's 18-21), while II is that
  same band sitting on a 16-20% floor of retained chroma across the rest of the wheel.

- **Applying a camera look through Apple's RAW engine.** After the visualiser, not before.
  `RawDevelopService` renders at `CIRAWFilter`'s defaults deliberately (Apple's engine on the file
  as the camera recorded it), but the filter also exposes `boostAmount` — how much of Apple's own
  tone rendering to apply, where 0 gives a flat linear render — along with `contrastAmount`,
  `sharpnessAmount`, the neutral/white-balance controls, and `linearSpaceFilter`, which injects an
  arbitrary `CIFilter` chain in linear space before the output colour-space conversion. That last
  one is where a grade would belong.

  Apple's pipeline does not read Olympus maker notes, which is exactly why an ORF renders as
  Natural, so none of this is automatic: the look would have to be implemented, and a faithful
  reproduction of an art filter is not realistic. Monochrome is the one cheap case — a contrast
  filter plus toning is ordinary darkroom physics rather than a proprietary curve, and both values
  are already parsed for all three routes.

  If built, it must be an opt-in second path. The existing develop route's value is that it is
  Apple's rendering and nothing else.

## Deliberately out of scope (for now)

- Flickr/other upload pipelines — treat as a separate integration, not core scope.
- Anything the reference app hasn't shipped yet (see its own backlog) shouldn't be assumed as a
  requirement here — build the above first, then re-derive next steps from real usage.
