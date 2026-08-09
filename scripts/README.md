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

`--force-focus` overwrites an existing `SubjectDistance` with the camera's own
`Olympus:FocusDistance` (when that's a usable finite distance; blank/`inf`/0 are
still skipped). It's the escape hatch for replacing a value you don't trust from
another tool. Note it is **not** needed for DxO PhotoLab exports: DxO already
copies the real `FocusDistance` into `SubjectDistance` faithfully, substituting a
placeholder only for infinity-focus frames (which the `inf` guard skips anyway),
so on DxO folders this flag rewrites identical values for no gain and forces a
full re-upload per file. Prefer the plain default there — where the focus pass is
typically a no-op and the alt-text pass does the useful work.

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

## make-hue-wheel.py

Generates the hue wheel that `CameraLookParsing.partialColorNames` was measured
from. Kept so that table is reproducible rather than a set of magic strings.

```
scripts/make-hue-wheel.py hue-wheel.png
```

Why it exists: exiftool has no name table for the art filter's Partial Color
ring — its PrintConv is literally `"Partial Color $val"` — so the eighteen
stops had to be measured. Displaying this wheel and shooting it once at every
stop makes each frame's surviving sector readable *by its position on the
wheel* rather than by its colour, which is what makes photographing a monitor
acceptable: the display's gamut and the camera's white balance shift the hue
but not the geometry.

The measurement (2026-08-08, OM-3, frames H1071790-H1071807) came out at
20.0 degrees per stop with stop 0 at 64.1 +/- 2.3 degrees — pure yellow is 60,
and the camera's own ring UI shows a yellow selector at top, which
independently fixes the anchor. Hence stop 0 = yellow, each further stop
stepping 20 degrees down in hue.

To redo it: display the wheel, shoot Partial Color at all eighteen stops with
consistent framing, then register each frame off the white and black hub
patches (their offsets from the wheel centre are fixed by the geometry at the
top of the script) and find the kept sector by normalising each angular bin
against the brightest that bin gets across all eighteen frames — an absolute
saturation threshold does not work, because the filter attenuates the rejected
hues rather than removing them. Turn off Night Shift and True Tone first;
a hue-shifted display is the one screen setting that genuinely biases the
result.

### Where the measured frames ended up

The metadata itself is in the repo, not just the conclusions drawn from it:
`Tests/MacPhotoMasterTests/Fixtures/CameraLookFixture.json` keeps one frame per
distinct maker-note signature — 154 of them, H1071741 to H1071932 — with the
exact `exiftool -j -G1 -a -s` text and the strings the parsers rendered from it.
That is the corpus to re-check against when the parsers change; the cards
themselves are not a durable record.

### Shading Effect is not monochrome-only

`Olympus:MonochromeVignetting` carries the Shading Effect slider, -5 to +5
through an unshaded 0 — a vignette running dark at the negative end to light at
the positive one. The tag name is Olympus's and it is narrower than the setting:
the *colour* profiles have the same slider, stored in the same tag. Confirmed at
the camera, and consistent with the files — H1071920 is a Colour Profile frame
reading +1, while H1071919, shot straight after a monochrome frame that set -2,
reads 0. So the value is held per picture mode rather than in one global
register, and `shading` appearing on a colour frame is correct rather than a
leak.

### The Shade Effect codes, 0x80a0 and 0x80a1

exiftool has no table for either, so both were read off the pixels
(H1071930/H1071931). Shading darkens two opposite edges, which is directly
measurable: `0x80a1` takes the top and bottom bands to 67% of centre luminance
while left and right stay at 110%; `0x80a0` is the reverse, 64% against 117%.
A known Blur Left and Right frame darkens nothing at all (128-134%), which is
what tells the two effects apart — Blur removes detail, Shade removes light.

Worth knowing: the pairing runs the *opposite* way to Blur's. `0x8080` is top
and bottom and `0x8081` left and right, but `0x80a0` is left and right and
`0x80a1` top and bottom. Extrapolating from Blur would have named both
backwards.

### Still to measure

One ring left. It blocks nothing today, but would remove a fudge from a future
look visualiser (docs/SPEC.md "Ideas, not started").

- ~~**Colour Creator.**~~ Done, 2026-08-09 — the table shipped in
  `CameraLookParsing.colorCreatorNames`. See "Colour Creator: what is known"
  below for the measurement and its caveats.
- **The twelve Colour Profile spokes.** `hueCodes` names them Y, O, Or, R, M, V,
  B, Bc, C, Gc, G, Yg — four names between yellow and red but only one between
  cyan and green, which suggests the spokes are not evenly spaced in hue.
  Nothing depends on the spacing today; drawing the wheel would.

### Colour Creator: what is known

Measured 2026-08-09 from frames H1071808-H1071857 (OM-3): a reference with the
effect off, a full sweep of all positions at strength +3, and partial sweeps at
-4, -2 and 0.

**The two axes.** `Color` picks a hue to pull the image toward. `Strength` is a
*bipolar saturation* control, not an intensity of the hue — the camera's own UI
names it **Vivid**, and the OM-3 header reads `Color <swatch>, Vivid -2`. At -4
the output is exact monochrome (R=G=B, verified at five colour indices and across
all 36 angular bins). At 0 saturation is near the untouched reference (0.864 vs
0.863); at +3 it is boosted (0.960). Negative values behave like Partial Color —
hues near the cast survive, distant ones collapse toward it. Position 0 imposes
no hue but still runs as a pure saturation control, which the camera confirms by
drawing an empty swatch in its header for that position.

Note the cursor's distance from the disc centre is Vivid, not a hue reading — at
COLOR 0 / VIVID 0 OM Workspace parks it on the inner circle at 12 o'clock, and it
moves inward as Vivid drops. An earlier reading of the camera screen took the
centred cursor as evidence for position 0 being neutral; the empty swatch is the
actual evidence, and the cursor position only says Vivid was low.

`CameraLookParsing` reports `color N (name) | vivid +/-N`, and annotates the
bottom of the range as `vivid -4 (mono)` because nothing else in the file says the
frame is black and white — the picture mode still reads "Color Creator".

The ring position is kept alongside that annotation rather than suppressed as
inert. At Vivid -4 the output carries no colour, but the cast is applied *before*
the desaturation, so the position still decides which hues render light or dark,
exactly as a B&W contrast filter does: across the five mono frames the per-sector
luminance profile moves by up to a third between positions. Direction only —
those frames had uncontrolled exposure (surround luminance ranged 35 to 89), so
the size of the effect is not pinned down. Worth a controlled set if the
visualiser ever needs to draw the mono case faithfully.

**The effect is a white-balance shift, and it lives only in the JPEG.** In the ORF,
`Composite:RedBalance`/`BlueBalance` and `Olympus:WB_RBLevels` are byte-identical
across every position — the RAW records the scene white balance untouched. In the
JPEG the same fields sweep smoothly with the position index, because the camera
folds the cast into the multipliers it records for the rendered file. Position 0's
JPEG gains equal the ORF's exactly, which is what makes position 0 a valid
reference white for the whole run.

**The measured table** (2026-08-09, frames H1071885-H1071915, Vivid -1, flat
neutral wall, exposure locked at 1/320 f/7.1 ISO 10000, all 30 positions with
position 3 shot twice). Hue is the sRGB hue angle of the mean wall patch, taken
against position 0 as neutral:

| pos | hue | pos | hue | pos | hue |
|----:|----:|----:|----:|----:|----:|
| 0 | neutral | 10 | 282 | 20 | 194 |
| 1 | 74 | 11 | 260 | 21 | 186 |
| 2 | 32 | 12 | 248 | 22 | 177 |
| 3 | 13 | 13 | 243 | 23 | 166 |
| 4 | 21 | 14 | 227 | 24 | 150 |
| 5 | 14 | 15 | 218 | 25 | 132 |
| 6 | 358 | 16 | 214 | 26 | 113 |
| 7 | 339 | 17 | 210 | 27 | 100 |
| 8 | 324 | 18 | 210 | 28 | 96 |
| 9 | 302 | 19 | 202 | 29 | 90 |

Hue decreases with the index, the same direction as the Partial Color ring.
Position 26 measures green, matching the green swatch the camera's own header
draws for it. Two caveats: positions 3, 4 and 5 read 13, 21, 14, which is not
monotonic — in gain space those three are perfectly ordered, so the wobble is
measurement noise, most likely hand-held framing drift across a wall that has a
mild luminance gradient. And cast saturation is not constant, running 17 percent
at the yellow-green ends against 45 percent at blue, so the low-chroma positions
(1-5, 26-29) carry the most angular uncertainty. The duplicate at position 3
brackets repeatability at 2.4 degrees.

**Ring geometry: 30 detents of 12 degrees, position 0 at 12 o'clock.** Settled
from OM Workspace's Color Creator panel, not from the frames. That panel labels
the ring 0, 5, 10, 15, 20 and 25 clockwise from the top at even spacing — six
labels 60 degrees apart, five positions each, so 30 x 12 = 360. Position 15 sits
diametrically opposite 0. A second screenshot at COLOR 11 puts the cursor ray at
131 degrees clockwise from 12 o'clock against 132 predicted, which fixes both the
direction and the anchor. The cursor's *radius* is Vivid, not its angle.

Since position 0 carries no hue, the 29 hue positions span 28 arcs = 336 degrees
and leave a 24-degree dead zone straddling the top. That is not recoverable from
the frames: the closing gap between position 29 and position 1 measures 0.41x to
1.29x of a mean step depending on the colour space, never the 2x the geometry
actually implies, because the local angular scale changes by 4x right across it
(step 28->29 is 4.7 degrees, step 1->2 is 19.4 degrees). A warped measurement of
the output cannot recover the ring's own spacing — read it off the vendor UI.

**The OM Workspace ring is painted decoratively and must not be used as a colour
reference.** Sampling its annulus at each position and comparing against the
measured table gives sd 31 degrees with errors to 76 degrees: positions 14-19
agree within 9 degrees, while 22-24 are 50-76 degrees out. It is a hue gradient
drawn to look like a colour wheel, the same as the camera's own ring. Only the
geometry above is trustworthy from it.

**Why the +3 sweep could not produce the table, and why -1 could.** Strength +3
clips the camera's own sRGB output — the red channel floors at 7-10/255 for
positions 21-23, and 25, 26 and 27 all render at roughly 150 degrees. At Vivid -1
nothing clips in the output, though the recorded red gain does pin at about 1.87
across positions 16-25, which is why no rotation-in-gain-space model fits and why
circle and ellipse fits to the gain locus both leave 16-18 percent radius scatter.
Measure the output, not the gains.

Auto white balance turned out to be harmless here despite the earlier worry: the
ORF proves scene WB never moved, so AWB was not chasing the cast. A fixed preset
is still the safer default if the run is ever repeated.

Worth ten minutes before shooting anything, though it may come to nothing:
Partial Color's marker field `0x1100` decodes as max 17 / min 0 under the same
byte packing Colour Creator writes its range in, which matches that ring's
eighteen stops. If `ArtFilterEffect` markers are packed ranges throughout, some
of the above is self-describing and needs no measuring. Grainy Film's `0x0500`
and Instant Film's `0x1300` do not obviously fit, so this is a hypothesis, not
a finding.
