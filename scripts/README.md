# scripts/

Dev-tooling scripts, not part of the app build.

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
