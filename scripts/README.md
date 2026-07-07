# scripts/

Dev-tooling scripts, not part of the app build.

## build-app-bundle.sh

Wraps the SPM release executable in a real `MacPhotoMaster.app` bundle so it can be pinned to the
Dock and double-clicked from Finder, instead of only being runnable via `swift run`.

Why: `swift run` execs the bare binary with no `Info.plist`/bundle identity — no stable Dock icon,
and a fresh ad-hoc code-signing identity on every rebuild that can force privacy grants (e.g. Files
and Folders access for Google Drive Timeline sync) to be re-approved. A proper `.app` fixes both:
a real `CFBundleIconFile` (built from `icons/purplegreenswallow1024x1024.png` via `iconutil`) and a
consistent `CFBundleIdentifier` (`com.briansmithphotos.macphotomaster`) that ad-hoc codesign can
re-sign identically across rebuilds.

```
scripts/build-app-bundle.sh
```

Builds `dist/MacPhotoMaster.app` (gitignored — a build artifact, not source). Drag it into
`/Applications` or straight onto the Dock. Ad-hoc signed only (`codesign --sign -`, no Developer ID)
— fine for running on this machine, not for distributing to others or passing Gatekeeper's
`spctl` assessment on a machine where it'd carry a quarantine attribute.

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
