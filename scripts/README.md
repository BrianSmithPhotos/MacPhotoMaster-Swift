# scripts/

Dev-tooling scripts, not part of the app build.

## build-app-bundle.sh

Wraps the SPM release executable in a real `MacPhotoMaster.app` bundle so it can be pinned to the
Dock and double-clicked from Finder, instead of only being runnable via `swift run`.

Why: `swift run` execs the bare binary with no `Info.plist`/bundle identity — no stable Dock icon,
and no code signature that TCC can key a privacy grant to (e.g. Files and Folders access for Google
Drive Timeline sync), so every rebuild re-prompts. A proper `.app` fixes both: a real
`CFBundleIconFile` (built from `icons/purplegreenswallow1024x1024.png` via `iconutil`) and a
consistent `CFBundleIdentifier` (`photos.briansmith.macphotomaster`).

```
scripts/build-app-bundle.sh
```

Builds `dist/MacPhotoMaster.app` (gitignored — a build artifact, not source). Drag it into
`/Applications` or straight onto the Dock. Signed with the `Apple Development` certificate rather
than ad-hoc, because TCC keys its grants to the signature and an ad-hoc one is just the binary's own
hash — it changes with every rebuild, so macOS sees a brand-new app each time and silently drops
anything previously granted. Certificate-backed signing is what lets the narrow grants the app
actually needs (removable volumes for the SD card, CloudStorage for `Timeline.json`) stick, instead
of reaching for Full Disk Access. Override with `CODESIGN_IDENTITY` on a machine without that
certificate; `CODESIGN_IDENTITY=-` restores ad-hoc signing. Still a development identity — fine for
running on this machine, not for distributing to others or passing Gatekeeper's `spctl` assessment
on a machine where it'd carry a quarantine attribute.

## backfill-standard-metadata.sh

Backfills two standard metadata fields into already-organized library photos that
were processed before the app learned to write them, so old files match what a
fresh Process & Move now produces:

1. **Focus distance** — copies `Olympus:FocusDistance` (a MakerNote only exiftool
   and this app read) into `EXIF:SubjectDistance` + `XMP-exif:SubjectDistance`, the
   standard fields Lightroom / Photo Mechanic / DxO display. Blank, `inf`
   (infinity) and `0` readings are skipped, matching the app's own rule.
2. **Alt text** — copies the existing caption (`XMP-dc:Description`, or
   `IPTC:Caption-Abstract`) into `XMP-iptcCore:AltTextAccessibility`.

Each pass only fills a gap — a file that already has the destination tag is left
untouched — so it's safe to re-run and never overwrites app-written or hand-edited
values.

```
scripts/backfill-standard-metadata.sh <directory>              # dry run: reports only
scripts/backfill-standard-metadata.sh --apply <directory>      # perform the writes
scripts/backfill-standard-metadata.sh --apply --year 2026 <directory>
scripts/backfill-standard-metadata.sh --apply --force-focus <directory>
```

Dry run is the default and writes nothing — it lists what each pass would change.
`--year YYYY` filters by `DateTimeOriginal` (the `<M Month>/<DD>/` library folders
carry no year), useful for limiting a run to one season's shots. Recurses across
`.orf`/`.jpg`/`.jpeg`.

`--force-focus` is for DxO PhotoLab exports: DxO writes its own `SubjectDistance`
on export (a generic "far" figure), which the gap-fill default leaves in place.
The flag overrides it with the camera's own `Olympus:FocusDistance` whenever that
reads as a usable finite distance — blank/`inf`/0 are still skipped, so
infinity-focused shots (where DxO's figure is as good as any) are left alone.

**Warning:** `--apply` uses `exiftool -overwrite_original` — no per-file backup.
It rewrites metadata only (image data is never touched), but run it against a
library you have a normal backup of (Time Machine etc.), and use the dry run first
to confirm the scope.

## strip-app-metadata.sh

Restores a folder of photos (typically a real SD card's DCIM folder) to a
camera-original state by clearing metadata this app (or its Python sibling,
`phototags`) writes — AI-generated captions/keywords/title and app-written
GPS coordinates/altitude — without touching anything the camera itself
embeds.

Why: several upcoming features (task #4 exiftool maker-note read wiring,
Timeline GPS-match wiring, the AI provider layer) are best tested against
real camera files in their true out-of-camera state, not files still carrying
metadata from earlier processing/testing passes. Re-run this before starting
a feature build that needs a clean source set.

```
scripts/strip-app-metadata.sh "/Volumes/OM SYSTEM/DCIM/105OMSYS"
```

Clears, recursively, across `.jpg`/`.jpeg`/`.orf`:
- `IPTC:Keywords`, `IPTC:Caption-Abstract`, `IPTC:ObjectName`
- `XMP-dc:Description`, `XMP-dc:Subject`, `XMP-dc:Title`
- `GPSLatitude`/`GPSLatitudeRef`, `GPSLongitude`/`GPSLongitudeRef`,
  `GPSAltitude`/`GPSAltitudeRef`

Deliberately left alone: `GPSVersionID` and a blank `IFD0:ImageDescription`
— both showed up as Olympus camera defaults on completely untouched RAW
files during testing (2026-07-03), not something either app writes.

**Warning:** uses `exiftool -overwrite_original` — no per-file backup, and
files are modified in place. Only run against a card/folder you have secure
copies of elsewhere (per docs/CLAUDE.md "Secrets & Privacy" — this script
itself never touches real Timeline exports or committed test fixtures, only
whatever directory you point it at).
