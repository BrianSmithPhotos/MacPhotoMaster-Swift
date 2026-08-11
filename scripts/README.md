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

### OM Workspace confirms the Partial Color geometry, not its colours

Workspace's art-filter panel draws the ring as an 18-stop wheel numbered 1-18
(exiftool numbers the same stops 0-17, so Workspace's "4" is our index 3), with
stop 1 at 12 o'clock and the index running clockwise. That independently
confirms the measured geometry: 18 stops, anchored at yellow, hue stepping down
about 20 degrees per stop. It is the second confirmation of the anchor after the
camera's own yellow selector at top.

Its *rendered* colours are decorative, though, exactly like the Colour Creator
ring in the same app. Sampling the annulus against the measured table gives a
mean offset of only -4.8 degrees but sd 19.1 and a worst case of 48 degrees:
stops 0-4 and 10-13 land within 8 degrees, while pink/magenta and
emerald/green/lime are 20-48 degrees out. Read geometry off this UI; never read
hue off it.

Workspace also offers controls the camera does not - a +/-7 saturation range
against the camera's +/-5, plus luminance and tint axes with no camera
equivalent, and a Color Filter list far longer than the five values the camera
writes to the `0x8060` record. None of that is in the files, so none of it
belongs in the look string or the visualiser.

### Partial Color I, II and III are three different things

Measured 2026-08-09 from H1071970-H1071978: types I, II and III at each of stops
3, 9 and 15 (red, blue, green), nine frames at a locked 1/50, f/14, ISO 3200,
WB 5300K. Registration off the hub patches, validated on the unfiltered
H1071945 — measured hue tracks wheel angle to a median +0.9 degrees, and the
recovered rotation is within 0.6 degrees of level on all ten frames.

`measure-partial-color.py` is the measurement, kept so the table below stays
reproducible. Reference frame first, then the filtered ones:

```
scripts/measure-partial-color.py REF.JPG FRAME.JPG [FRAME.JPG ...]
```

Measure **chroma** (`max-min`), not saturation. Saturation is `(max-min)/max`,
which inflates wherever `max` is small, and blue is the dimmest hue the display
renders — in S the blue residual below reads about twice its real size. Same
family of trap as the Colour Profile spokes above, caught by the fact that the
unfiltered wheel's own chroma is nearly flat across the sectors (0.60-0.75) with
blue the *highest*, so a genuine blue excess cannot be a dark-pixel artefact.

Each frame normalised to its own peak; edge is the 90%-to-10% fall, averaged
over the two sides:

| Type | Stop | Centre | FWHM | Edge 90-10% | Out-of-band floor |
|------|------|-------:|-----:|------------:|------------------:|
| I | red | 360.0 | 62 | 21 | 0.000 |
| I | blue | 248.0 | 70 | 21 | 0.000 |
| I | green | 122.0 | 62 | 18 | 0.000 |
| II | red | 360.0 | 62 | 23 | 0.195 |
| II | blue | 239.0 | 80 | 98 | 0.157 |
| II | green | 112.0 | 86 | 107 | 0.170 |
| III | red | 360.0 | 66 | 14 | 0.000 |
| III | blue | 248.0 | 70 | 11 | 0.000 |
| III | green | 121.0 | 64 | 4 | 0.000 |

**All three share the same band centres**, so the eighteen names in
`partialColorNames` are valid across I, II and III. The type changes the band's
edges and floor, never its position.

**I and III differ only at the shoulders.** Both keep the same 62-70 degree
band; III's edges are 4-14 degrees against I's 18-21, so III is 1.5x to 4x
sharper. III is not a narrower band, it is the same band cut harder.

**II is not a wider band, it is an incomplete desaturation.** I and III write
*exactly* neutral pixels outside the band — the floor is 0.000, not merely
small. II leaves 16-20% of the original chroma standing across the whole rest of
the wheel. Its larger FWHM in the table is mostly that floor lifting the
half-max point rather than real broadening, and its "edge" of 98-107 degrees is
not an edge at all: the profile never falls to 10% of peak, so there is nothing
to measure between.

**II's floor is strongly hue-dependent**, varying up to 6x around the wheel:

| Kept stop | Residual peaks at | Bottoms at |
|-----------|------------------:|-----------:|
| red (0) | 0.318 at 199 (cyan-blue) | 0.053 at 71 |
| green (121) | 0.246 at 193 (cyan-blue) | 0.077 at 41 |
| blue (248) | 0.263 at 37 (orange) | 0.108 at 319 |

Note this is not adjacency leakage — for the red stop the survivors sit on the
*opposite* side of the wheel. A complement rule would fit red (180 predicted
against 199 measured) and roughly blue (68 against 37) but not green (301
against 193), so three stops are not enough to name the mechanism. What is
solid: wherever blue is not the kept hue, blue is the hue that survives II best.

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

Nothing. Every ring the camera writes has now been measured off real frames, so
the look visualiser (docs/SPEC.md "Ideas, not started") has no fudges left to
remove.

- ~~**Colour Creator.**~~ Done, 2026-08-09 — the table shipped in
  `CameraLookParsing.colorCreatorNames`. See "Colour Creator: what is known"
  below for the measurement and its caveats.
- ~~**The twelve Colour Profile spokes.**~~ Done, 2026-08-09. The guess below was
  right: they are not evenly spaced. See "The Colour Profile spokes" for the
  measured centres. Still nothing depends on the spacing today; drawing the
  wheel would.

### The Colour Profile spokes, and why saturation was the wrong thing to measure

Measured 2026-08-09 from H1071933-H1071945: a reference with all twelve spokes
at 0, then one frame per spoke at +5, in camera order. Exposure manual and
identical throughout, WB manual 5300K, `WB_RBLevels` byte-identical `564 434 256
256` across all thirteen — so nothing but the spoke moved.

The obvious measurement fails. A spoke sets *saturation*, so the intuitive
approach is to difference saturation against the reference — but the hue wheel
is drawn at HSV S=1 and the camera renders it essentially clipped: 41 of 72
five-degree bins sit above S 0.99, with headroom only around 55-65 and 135-145
degrees. Every spoke's apparent peak then landed in one of those two dips
regardless of which spoke had moved, putting Red at 152 degrees and Blue-cyan at
62. That result measures the target, not the camera.

Value carries the signal instead. Where saturation cannot rise it is pushed out
of gamut, and the clip shows up as a luminance shift, so differencing V against
the reference gives one clean contiguous lobe per spoke, peaking +0.045 to
+0.239. Centres are the circular centroid of the above-half-max bins:

| # | Spoke | Centre | Gap to next |
|--:|-------|-------:|------------:|
| 1 | Yellow | 42.6 | 18.4 |
| 2 | Orange | 24.3 | 34.5 |
| 3 | Orange-red | 349.8 | 19.0 |
| 4 | Red | 330.7 | 11.7 |
| 5 | Magenta | 319.0 | 29.5 |
| 6 | Violet | 289.5 | 44.1 |
| 7 | Blue | 245.4 | 35.2 |
| 8 | Blue-cyan | 210.2 | 14.7 |
| 9 | Cyan | 195.5 | 38.1 |
| 10 | Green-cyan | 157.3 | 35.3 |
| 11 | Green | 122.0 | 43.7 |
| 12 | Yellow-green | 78.3 | 35.7 |

Degrees are `make-hue-wheel.py` wheel angle, which equals displayed hue by
construction. The twelve are strictly ordered, they run anticlockwise in
increasing camera index, and the gaps close to exactly 360.

The spacing is genuinely uneven, from 11.7 to 44.1 degrees, and it is uneven the
way the *names* are: yellow through red is four spokes across 72 degrees, while
the single Green-cyan spans the 73 degrees from cyan to green. That is what
perceptual hue naming looks like — we discriminate warm hues far more finely
than greens — so the camera's twelve bands are perceptually spaced, not
geometrically.

Caveat worth carrying: these centres come from an out-of-gamut side effect
rather than from the saturation change itself. The clip is strongest where the
boost is strongest, so the lobe centre should be the band centre, but it is an
indirect estimator. It is a stable one — re-running against the inner half of
the ring, the outer half, and a different threshold moves no centre by more than
1.7 degrees, and eight of the twelve by under a degree. If a future measurement
ever needs the band *widths* rather than their centres, shoot a wheel drawn at
about S 0.5 so a saturation boost has room to register directly.

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

## make-tone-ramp.py and measure-tone-curve.py

The tone half of the look visualiser (docs/SPEC.md, groups 3-6): Highlight,
Midtone and Shadow at +/-7 each, Contrast at +/-2, and Gradation. **Not yet
measured** — this is the shot list and the tooling, written 2026-08-10 before
the frames exist.

**The camera's own structure does most of the work here.** Gradation and the
tone curve are mutually exclusive, and not merely as a setting: Gradation belongs
to the standard picture modes, the Highlight/Midtone/Shadow curve belongs to the
Color and Monochrome Profile modes, and no frame can carry both. Contrast sits on
top of either. So the composite the visualiser draws is only ever *one* tonal
control composed with contrast — never three tone axes plus a gradation preset.

That also fixes the shape of the measurement: **each mode needs its own reference
frame.** Measuring a Color Profile frame against a Natural reference would fold
the difference between two picture modes into what is supposed to be one
setting's curve.

```
scripts/make-tone-ramp.py ramp.png
scripts/measure-tone-curve.py REF.JPG FRAME.JPG [FRAME.JPG ...]
scripts/measure-tone-curve.py --compose REF.JPG A.JPG B.JPG AB.JPG
scripts/measure-tone-curve.py --csv curves.csv REF.JPG FRAME.JPG ...
```

Why it exists: the camera and OM Workspace both draw these settings as *two*
curves — one for Highlight and Shadow, a second for Midtone — which shows what
was dialled in, not what came out. The visualiser wants the single curve the
image actually got. That can only be had by measuring, the same way the rings
were, and Workspace is no help as a reference: it offers a -10 Shadow value the
camera's own +/-7 range cannot express, so its rendering is its developer's, not
the camera's.

### How the measurement works, and what it cannot do

`measure-tone-curve.py` recovers T(x) by matching cumulative histograms: the
output level whose cumulative histogram in the test frame equals the reference's
at input x. It never pairs pixels, so it does not care about framing — small
tripod drift between frames would otherwise be folded into the curve as noise,
worst exactly where the scene has edges.

The price is an assumption: that the setting is a monotonic *global* function of
level. That holds for the tone sliders and for High/Low Key. It does **not** hold
for **Gradation Auto**, which is a scene-adaptive local operator — there is no
single curve to find, and no shot list can produce one. The parser already treats
Auto as a flag rather than a curve (`gradationIsAuto`), and the visualiser should
say "Auto" rather than draw anything.

Measurement is in the JPEG's own encoding, not linearised. The curve worth
drawing maps stored level to stored level, because that is the one the viewer
sees.

### The target and the setup

Display `ramp.png` full screen. It is a full-bleed linear grey ramp with no
markings — histogram matching needs no registration features, so unlike the hue
wheel this target tolerates being shot slightly crooked, and blurred. It does not
tolerate being shot freehand, because a pan between frames slides the frame along
the ramp; see the tripod note below. What it
does need is every level populated: the generated ramp's thinnest level holds
0.23 percent of the frame against the script's 0.01 percent floor, so there is
room for the camera to compress a region and keep it measurable.

Night Shift and True Tone off, and display brightness fixed for the whole run —
the same screen settings the hue wheel needed, for the same reason.

**Turn off "Automatically adjust brightness" in System Settings > Displays.**
Fixing the brightness slider is not enough: with auto-brightness on, the display
re-reads the room and moves the backlight on its own, so the slider stays put
while the light output does not. This is half of what voided the second attempt.

**Shoot in the dark — lights off — not merely in a dim room.** The ramp fills the
frame, so the display is the only thing in the picture, and every other photon in
the room reaches the sensor by reflecting off the glass. That reflection is
additive light: it is negligible against a white ramp column and overwhelming
against a black one, so drifting ambient light warps the bottom of the curve
while leaving the top nearly untouched — which is indistinguishable from a Shadow
adjustment. Daylight through drawn blinds is not stable enough; cloud cover
modulates it over minutes, and it does not drift in one direction, so it cannot
be interpolated out afterwards either. This is the other half of what voided the
second attempt.

**Pick the time of day from which way the windows face**, which matters more than
how dim the room looks when you walk into it. The stable window is when the sun
is not on that side of the building at all, because then only indirect skylight
gets in and it changes slowly. The room used here faces west, so mornings are
stable and afternoons are the worst possible choice — the second attempt was shot
at 15:04 to 15:18 in August, which is exactly when the sun swings round onto that
glass. After full dark is stable whichever way the windows face.

**Also disable display sleep and the screen saver.** Automatic dimming is the
same failure with a shorter fuse, because a sequence of 10 to 20 frames easily
outruns the default sleep timer. Generate the
ramp at the display's native resolution and matching its aspect ratio (5120x2880
for a Studio Display) so it fills the screen without letterbox bars; black bars
would put a spike at level 0 and clip the bottom of every frame.

**Show the ramp as the desktop wallpaper, not in an image viewer.** A viewer in
full screen still draws its own chrome over the picture, and chrome is a flat
plateau of near-white pixels that the ramp itself never produces. Measured on
macOS 27 beta with Preview full-screen: a 97-pixel band across the top of the
panel, 3.8 percent of its height, captured at 240 to 245. The ramp alone reaches
level 239, so *every* level above that in such a frame comes from chrome rather
than from the target — and a flat plateau is a step in the cumulative histogram,
which is exactly the shape that carries no information about where the curve
goes. Highlight +7 is the setting that works up there.

The band is survivable while it is identical in every frame, because it is part
of the scene and the camera curves it like everything else. The danger is that it
is not: chrome auto-hides, toolbars appear, the pointer wanders into shot. A band
present in one frame and absent from its reference is worth up to **+10.2 levels**
at level 232 and **+7.1** at 128 — two to three times the independence threshold,
one-signed, and indistinguishable from the room having drifted. Wallpaper has no
chrome by construction, and the file maps one image pixel to one display pixel.
Hide the desktop icons and any desktop widgets, set the Dock and the menu bar to
auto-hide, and keep the pointer parked off the panel or in a corner.

**Frame so the ramp fills the viewfinder** — no bezel, no wall, no desk. Anything
else in shot is scene content whose levels are not under control, and on the first
attempt it was the room, not the target, that carried the drift. Setting the
camera's aspect ratio to 16:9 rather than its native 4:3 is the tidy way to lose
the bezels above and below a widescreen display: it is a sensor crop, so it
changes what is in frame without touching how tones are rendered.

Shoot one deliberately *wrong* frame first, though — pulled back far enough to
show the bezel on all four sides. Filling the viewfinder hides the panel edges,
which is exactly where chrome lives, so a correctly framed check frame cannot
tell you the screen is clean. The pulled-back frame can: the panel's own edges
give the scale, anything bright sitting against them is chrome, and the whole
diagnosis costs one shot. This is how the Preview band above was found, after
four correctly framed check frames had shown nothing wrong.

Focus last, after everything else is in position, and remember that manual focus
does not follow the camera or the screen when either is moved — autofocus once on
the ramp, switch back to MF, then leave it alone for the whole run.

**The tripod has to hold position across the whole run; it does not have to hold
still during a frame.** These are worth separating, because the intuition from
normal photography points at the wrong one. Camera shake is nearly free against
this target — 40 pixels of motion smear, enough to ruin an ordinary photograph,
costs 0.0 levels in the midtones and 1.0 at the extreme top, because a linear
ramp convolved with a symmetric kernel is the same linear ramp away from its
edges. A shutter delay is worth taking since it costs nothing, but it is not the
variable that matters.

Movement *between* frames is the one that matters, because the frame sits inside
the display: panning slides it along the ramp and changes which levels are in
shot, which reads back as a uniform level offset and looks exactly like the light
having changed. Measured on a 5120-pixel-wide ramp carrying 255 levels, that is
0.05 levels per pixel:

| camera nudged sideways | false curve it invents |
| --- | --- |
| 5 px | +0.2 levels |
| 20 px | +1.0 |
| 60 px | +3.0, the whole independence threshold |
| 150 px | +7.5 |

Sixty pixels is 1.2 percent of the frame width. A nudge the other way brings
bezel into shot, which puts a spike at level 0 and corrupts the shadow end while
staying under the clipping warning, so both directions cost. This is the real
argument for a rigid tripod and for turning the camera's dials gently — and it is
the second reason to interleave the references, since a bump shows up as
disagreement between the two references bracketing the frame.

A pan is still distinguishable from a light change if both happen: a pan shifts
both ends of the captured range by the same number of levels, where changing
light moves the dark end proportionally much more. That is the test that ruled a
camera move out of the second attempt.

**Then check the dark end for reflections before shooting the set.** A glossy
display reflects the room, and the reflection is only visible where the ramp is
dark — which is exactly where the Shadow control does its work, and where a few
levels matter most. On the second attempt (H1072021) a window reflected into the
top-left corner and lifted it 43 levels on average and 171 at its peak, over 2.6
percent of the frame. Worse, a window is daylight: it drifts over a 10-frame
sequence, which is the failure that voided the first attempt. Kill the reflection
rather than hoping it holds still — curtain it, or angle the camera so the bright
part of the room does not fall in the lens's mirror image. Move the mouse pointer
off the screen too.

Optional but free: set a custom white balance off the ramp itself. The display's
white point does not match a 5300K preset, so the capture carries a colour cast
(H1072021 read R 131, G 146, B 149), and that cast is enough to make the `chan`
reading below meaningless — it cannot then separate a genuine per-channel curve
from the cast. The luma curve, which is what gets drawn, is unaffected either way.

- **Full manual exposure, fixed for every frame**, and manual WB. Any exposure
  change is indistinguishable from a tone curve.
- **Expose so nothing clips, and accept that the headroom is lopsided.** The
  settings being measured are what push tones toward the ends, so an exposure
  that only just fits the reference guarantees the test frames clip: the first
  attempt (2026-08-10) filled 2-251 on a room scene and then crushed 12-15
  percent of the frame to black on every darkening setting. Clipping cannot be
  recovered in software — once tones are flattened onto 0 or 255 the cumulative
  histogram has a step there and no inverse. The script reports the clipped
  fraction at both ends of the reference and warns above 0.5 percent.

  An earlier version of this section asked for black at 20 and white at 235. That
  is not achievable with a full-range ramp on a good display, and the second
  attempt showed why: at 1/8 f/5.6 ISO 250 the ramp landed at 12-222 with nothing
  clipped, and the display's own black-to-white range is wider than the camera's
  output range, so the bottom cannot be lifted without the top clipping. A third
  of a stop more would put white at about 246 — no room left for Highlight +7 —
  while moving black only from 12 to 14. **Leave it there.** Highlight +7 lifts
  the top by about 20 levels and fits; Shadow -7 will crush the darkest few
  percent, and losing the curve below input 12 is the cheaper loss.
- **Autofocus once on the screen, then switch to manual focus and do not touch
  it.** AF left on refocuses per frame, and at f/2.0 that moves the focus plane by
  centimetres — which changes the histogram independently of any tone setting,
  because blurring averages neighbouring pixels and averaging then curving is not
  the same as curving then averaging. The first attempt left AF on and the focus
  distance wandered 1.895 to 2.245 m.

  Exact focus barely matters here, though *fixed* focus does: the ramp is smooth,
  so blurring it leaves it almost unchanged, which is a real advantage of this
  target over a scene with detail. If the display's pixel grid produces moire,
  defocusing slightly is the cure and costs nothing. Stopping down to f/5.6-f/8
  is still worth it for evenness across the screen.
- **Shoot JPEG** (RAW+JPEG is fine for provenance, but measure the JPEG). These
  settings are a rendering, and the ORF does not carry them — the same thing the
  Colour Creator measurement above established about white balance.
- **Picture Mode changes between groups, and only between groups.** It is what
  decides whether the camera offers Gradation or the tone curve at all, so it
  cannot be held fixed across the whole run — which is exactly why each group
  carries its own reference frame. Within a group it never moves.
- In the Color Profile groups, **set all twelve hue sliders to 0** so the only
  thing moving is the tone control. Worth confirming the way the spoke
  measurement did: run exiftool across the group and check nothing but the
  intended field differs frame to frame.
- Sharpness and Noise Filter fixed, ISO fixed and low. Sharpening works on edges
  and a smooth ramp barely gives it any, but there is no reason to let it vary.

### The shot list, about 41 frames

Three references, one per picture mode used: **REF-C** (Color Profile, all tone
levels 0, all twelve hue sliders 0, contrast 0), **REF-N** (Natural, Gradation
Normal, contrast 0) and **REF-M** (Monochrome Profile, all neutral). Every frame
is measured against the reference from its own mode.

**Shoot each reference twice — once at the start of its group and again at the
end — and check them against each other before trusting anything else in the
group.** This is the control that makes the run interpretable, and the first
attempt (2026-08-10) had no repeat reference, which is why it could not be
salvaged. Measure one against the other:

```
scripts/measure-tone-curve.py ref-c-start.jpg ref-c-end.jpg
```

Two frames with identical settings must give the identity curve, so `max dev` is
a direct reading, in levels, of everything that drifted while the group was shot
— room light, display output, anything. A few levels is fine and can be treated
as the measurement's noise floor. Tens of levels means the group is void: an
illumination change is indistinguishable from a tone curve, because both are
"every pixel came out at a different level than before".

**For group A, shoot the reference between every setting frame** — REF, H+7, REF,
M+7, REF, and so on. Bracketing the group at its two ends detects drift but
cannot correct it, which is exactly where the second attempt died: the closing
reference proved 12 levels of drift and there was nothing to be done with the ten
frames in between. Interleaving makes each setting measurable against a reference
shot 20 seconds earlier instead of four minutes, and turns consecutive references
into a continuous record of what the room is doing. It costs 11 extra frames on
the one group that decides the whole design. If those references come back within
a level or two of each other, the environment is proven stable and groups B to E
can go back to bracketing at the ends only.

**Shoot group A first and measure it before shooting anything else.** It decides
whether the remaining 30-odd frames are the right ones.

**Group A — is the tone curve separable? Color Profile. (REF-C + 9 frames)**

| singles | pairs |
|---|---|
| H +7 | H +7, S -7 |
| M +7 | H +7, M -7 |
| M -7 | M +7, S -7 |
| S -7 | Contrast +2, H +7 |
| Contrast +2 | |

Run each pair through `--compose`, giving the two singles then the combined
frame:

```
scripts/measure-tone-curve.py --compose ref-c.jpg h+7.jpg s-7.jpg h+7_s-7.jpg
```

If every pair comes back `independent`, the whole visualiser is three measured
basis curves plus contrast, composed in series — a small, clean implementation,
and group B's sweep is all that is left to shoot. If any pair comes back
`INTERACTING`, that axis needs measuring on a grid instead, and the shot list
below is the wrong one. There is no point designing the drawing before knowing
which.

The pairs are the ones most likely to interact: the two extremes (H against S),
and each adjacent pair, whose ranges plausibly overlap. Contrast is tested here
rather than assumed separate because it is a tone curve like the others and
belongs in the same composite — which is why SPEC moves it from group 4 into
group 3.

**Group B — the sweep. Color Profile. (20 new frames)**

Eight values per channel — -7, -5, -3, -1, +1, +3, +5, +7 — for Highlight,
Midtone and Shadow. Four of those 24 (H +7, M +7, M -7, S -7) are already shot in
group A. Eight rather than all fifteen because the visualiser interpolates
between measured curves anyway, and a slider this smooth does not need every
detent measured; 0 is REF-C.

**Group C — contrast. Color Profile. (3 new frames)**

-2, -1, +1. (+2 is in group A.)

**Group D — gradation. Natural. (REF-N + 4 frames)**

High Key, Low Key, one Auto frame for the record, and (High Key, Contrast +2).

The Auto frame is not measurable, as above; it is worth having so the failure is
documented against a real file rather than asserted. The last frame is the
`--compose` test for contrast over gradation — the counterpart of group A's
contrast pair, and needed because this is the only place the two can meet.

**Group E — does the same setting mean the same thing in another mode? (REF-M +
3 frames)**

- Natural, Contrast +2. Compare the recovered curve against group A's Color
  Profile Contrast +2. If they match, contrast is one mode-independent curve and
  the app stores it once; if not, it needs measuring per mode.
- Monochrome Profile, S -7 and H +7, against REF-M. Same question for the tone
  curve: the Color and Mono Profile modes both offer it, and whether they render
  it identically decides whether the app needs one table or two.

Do not read `chan` on the mono frames — the output is neutral by construction, so
it says nothing there.

### Reading the output

```
frame                     16    32    64    96   128   160   192   224   240   max dev   chan       tones
h+7.jpg                 16.2  32.1  64.0  95.8 127.1 156.3 180.2 198.4 210.1  -29.9@240   1.20       2-254
```

- The nine numbered columns are output level at that input level, and `tones` is
  the range the reference actually constrained. Anything outside it prints `-`.
- `max dev` is the furthest the curve strays from the identity diagonal and the
  input level where that happens — the one-line summary of what the setting does.
- `chan` is the widest disagreement between the recovered R, G and B curves. The
  target is neutral by construction, so any spread came from the camera. A low
  reading means the setting works on luminance and a single grey curve is the
  right graphic; a reading several times higher means the channels are being
  curved separately and it is not. Read it by comparing frames, not against zero.

`--csv` writes the full 256-level curves, which is the form the app will want
them in.

**`--paired`** takes the whole interleaved sequence in capture order — reference
first, reference last, a reference between every setting frame — and measures
each setting against the two references bracketing it rather than against one
reference at the far end of the run:

```
scripts/measure-tone-curve.py --paired --compose \
    ref0.jpg a.jpg ref1.jpg b.jpg ref2.jpg ab.jpg ref3.jpg
```

It adds two things to the output. A `reference stability` block compares each
consecutive pair of references and prints the worst, which is the run's own
record of what the room did while it was shot; read every result against it,
because a setting whose deviation is no larger has not been measured. And a
`drift` column gives each frame its own error bar — how far its two bracketing
references disagree.

Averaging the two transfer curves corrects linearly for drift, which is honest
only over the seconds an interleaved reference brackets. It is not a way to
rescue a run whose references sit minutes apart: see the second attempt below,
where the drift turned out to be a V in time, so a fit across the run would have
been wrong in the middle by more than the effect being measured.

Validated against synthetic frames built from a known curve and a known drift:
with no drift it recovers the composition exactly (0.00 rms) and reports
`independent`; with realistic drift it reports `independent` at 0.14 rms; with a
deliberately brutal V-shaped drift it cuts the error 4.4-fold (9.11 to 2.06 rms)
and correctly ranks the true model first, while flagging the references as
`DRIFTING`. The control that matters most: a genuine interaction with no drift is
still caught (4.17 rms) and is distinguishable, because its mean error is +0.51 —
near zero and two-signed — where drift produces the one-signed means seen below.

### First attempt, 2026-08-10: void, and why

Frames H1072011-H1072020 (OM-3, Color Profile 1, 1/20 f/2.0 ISO 100, WB 5300K)
covered group A's ten slots. They do not answer the question, and the run is kept
here as the record of what to control rather than as a measurement.

What was right: the settings were dialled correctly on eight of ten frames, the
exposure was fixed, `WB_RBLevels` was byte-identical `562 434 256 256` across all
ten, and the reference covered levels 2-251 with 0.00 percent clipped at either
end.

All four composition tests returned `INTERACTING` under every model, at 9-29 rms
levels. That reads like a finding about the camera and is not one, because the
errors are **one-signed**: every combined frame came out brighter than any model
predicts, with mean errors of -10.8, -10.7, -25.7 and -24.3 levels. A genuine
interaction wanders either side of zero. A one-signed bias means something moved
between frames — and the four biases fall into two tight clusters that track
capture time (the pairs completed at 11:47-11:48 biased about -10.7, those at
11:49 about -25), over a run lasting 4 minutes 22 seconds.

Illumination drift is the obvious candidate and cannot be confirmed from the
files: EXIF `LightValue` is computed from the exposure settings, so it reads a
constant 6.3 across the run and probes nothing. **Without a repeat reference frame
there is no way to separate a scene that got brighter from a camera that curves
tones, because both say "every pixel came out at a different level".** That
control is now first in the shot list above.

Three further defects, listed so the reshoot fixes all of them at once:

- **Autofocus was on at f/2.0**, and focus distance wandered 1.895 to 2.245 m
  across a scene metres deep. Refocusing redistributes levels independently of
  any tone setting.
- **The exposure filled the range**, so the settings had nowhere to go: the four
  darkening frames crushed 12-15 percent of the frame to black and H1072020 blew
  5.9 percent to white. Excluding the clipped levels does not rescue the models,
  so this is not the whole story, but it is not recoverable either.
- **H1072013 and H1072014 carry Highlights +1**, not 0, so the two Midtone
  singles are really (H+1, M+7) and (H+1, M-7). Two of the four composition tests
  depended on them.

The target was a room interior rather than the ramp. That is legitimate in
principle — coverage was good — but it is what brought the focus and
scene-stability variables in, and it is why the flat ramp is worth using.

### Second attempt, 2026-08-10: void, and what it proved

Frames H1072023-H1072033 (OM-3, Color Profile 1, 0.4s f/5.6 ISO 200, manual
exposure, manual WB, MF, 16:9, the generated ramp full-bleed) covered group A
correctly: all ten settings dialled exactly as listed, byte-identical exposure
and white balance across the group, no clipping at either end, and the whole run
took 4 minutes 29 seconds. The frame checked beforehand (H1072022) passed every
gate — levels 4-227, 0.000 percent clipped at both ends, identity curve against
itself, all three tone levels 0.

**The repeat reference did its job and voided the group: `max dev +12.0 @109`,
one-signed.** That is the control working as designed rather than a new failure —
attempt 1 had the same drift and no way to see it.

Four measurements identify the drift as scene illumination, not the camera:

- **Not a camera move.** A pan shifts every level-crossing along the ramp by the
  same number of pixels. The crossings for levels 64, 128 and 192 moved +270,
  +309 and +451 — progressively more toward the bright end, which is what a
  brightness change does and a translation cannot.
- **Not a settings change.** Exposure, ISO, `WB_RBLevels`, focus mode and picture
  mode are identical across all eleven frames.
- **Not a white-point shift.** R minus B held between -12.8 and -13.7 throughout,
  so True Tone and Night Shift were not moving.
- **Not the camera's processing.** The JPEG pipeline is deterministic: identical
  settings producing different output means the input changed. EXIF cannot
  confirm this directly — the OM-3 writes no `MeasuredEV`, and `LightValue` reads
  a constant 5.3 because it is computed from the exposure settings.

The *shape* of the drift names the mechanism. Between the two references the dark
end rose by a factor of 1.55 while the bright end rose by only 1.02. Neither a
pure gain nor pure additive stray light explains both, so it is both at once:
ambient light reflecting off the glass (dominant where the ramp is black,
negligible where it is white) plus a small backlight change. Daylight through
drawn blinds, and a display left on automatic brightness, produce exactly that
pair. Hence the two setup rules added above.

**The drift could not be interpolated away**, which is worth knowing before
anyone tries. Three same-settings frames exist — 15:04, 15:14 and 15:18 — and the
middle one is the *darkest* of the three. The drift is a V, not a slope, so a
correction fitted between the bracketing references would be wrong in the middle
by more than the effect being measured. Cloud cover over an afternoon behaves
this way; this is why the fix is to remove the ambient light rather than to model
it.

What the run does support, qualitatively, is that the three controls act on
separable regions — and drift cannot manufacture that, because it moves the whole
range at once. Highlights +7 reads 16.8 at input 16 (identity, to within noise)
and +30.3 at 205. Shadows -7 reads -25.2 at 38 and is near-identity at the top.
Midtones pivots the middle. Encouraging for the composition model, but not a
measurement of it: three of the four composition tests carry one-signed mean
errors of +4.2 to +11.8 levels against a 3-level threshold. The fourth, contrast
against highlights, came in at 2.09 rms under "serial a-then-b" — the closest any
test has come to independent, and the first thing to re-check on the reshoot.

