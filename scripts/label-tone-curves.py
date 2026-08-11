#!/usr/bin/env -S uv run --no-project --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Turns the per-run curve exports into one labelled table the app can consume.

`measure-tone-curve.py --csv` writes columns headed by frame filename, because that is all it
knows. This reads the camera's own maker notes back off those frames and renames each column to
the setting it was shot at - "Highlight +5", "Contrast -2", "High Key" - producing a single
`tone-curve-table.csv` that no longer needs the SD card to be readable.

Only single-dial frames go in. The runs also contain composition frames (two dials at once) and
repeated anchor exposures; both were measurements about the *protocol*, not entries in the table,
so they are dropped here. See scripts/README.md for what each run was.

The measured domain is roughly input 2 to 228: below that the reference frame has too few pixels
per level to match, and above it the displayed ramp simply has no brighter tone. Both ends are
extended to the corners (0,0) and (255,255) - a straight line at the dark end, where the span is a
level or two, and a monotonic cubic at the bright end, where 27 levels of straight line put a
visible corner in the contrast curves. Either way it is an approximation confined to the outer
tenth of the plot. Levels are kept as floats; the app rounds when it draws.
"""
import argparse
import csv
import re
import subprocess
from pathlib import Path

# The runs, in the order a setting should be taken from them. Each setting's own sweep lives in
# one run, so preferring that run keeps a dial's curve internally consistent; the +-7 endpoints
# and Contrast +2 were only ever shot in group A, so those cross a run seam worth about 2 levels
# (the anchor's measured repeatability - scripts/README.md "Groups B and C measured").
RUNS = ["group-bc-sweep.csv", "group-a-color-profile.csv", "group-d-natural.csv"]

# Repeated Highlight +7 exposures shot at the seams of the group B/C run to track drift. They are
# the same setting as the sweep's own Highlight +7 and would otherwise compete with it.
ANCHORS = {"H1072075.JPG", "H1072107.JPG", "H1072130.JPG"}

DIALS = {"Highlights": "Highlight", "Midtones": "Midtone", "Shadows": "Shadow"}


def read_settings(frame: Path) -> dict[str, str]:
    """The four maker-note fields that identify a tone frame, as raw exiftool strings."""
    tags = ["Olympus:ToneLevel", "Olympus:PictureModeContrast", "Olympus:Gradation"]
    out = subprocess.run(
        ["exiftool", "-s", "-T", *[f"-{tag}" for tag in tags], str(frame)],
        capture_output=True, text=True, check=True,
    ).stdout.strip("\n")
    tone, contrast, gradation = out.split("\t")
    return {"tone": tone, "contrast": contrast, "gradation": gradation}


def label(settings: dict[str, str]) -> str | None:
    """The setting name for a frame, or None if it is not a single-dial table entry.

    `ToneLevel` is a flat list - "Highlights; 7; -7; 7; Shadows; 0; -7; 7; ..." - where each dial
    is followed by its value and then its own min and max, so the value is the field after the
    name and the two after it are limits, not settings.
    """
    fields = [f.strip() for f in settings["tone"].split(";")]
    dials = {
        DIALS[name]: int(fields[i + 1])
        for i, name in enumerate(fields)
        if name in DIALS
    }
    contrast = int(re.match(r"-?\d+", settings["contrast"]).group())
    gradation = settings["gradation"].split(";")[0].strip()

    if gradation in ("High Key", "Low Key"):
        # Gradation overrides the contrast dial, so a non-zero contrast here is a value the
        # camera recorded and ignored - it does not make this a two-setting frame.
        return gradation if not any(dials.values()) else None
    if gradation != "Normal":
        return None

    moved = {name: value for name, value in dials.items() if value != 0}
    if contrast != 0:
        moved["Contrast"] = contrast
    if len(moved) != 1:
        return None
    name, value = moved.popitem()
    return f"{name} {value:+d}"


def extend(levels: list[float | None]) -> list[float]:
    """Drops the unreliable top level, then fills the unmeasured ends with a line to each corner.

    The brightest level the matcher reports is where the reference's cumulative histogram reaches
    1.0, so it matches the *brightest pixel in the test frame* rather than a populated level -
    the displayed ramp's white end is a thin sliver and a single hot pixel moves it. It shows up
    as a step of up to +9.9 levels where the neighbouring steps are +1.0. Dropping exactly one
    level fixes every column; the dark end does not have the mirror problem, because black is a
    large area of the frame and stays well populated.
    """
    measured = [i for i, value in enumerate(levels) if value is not None]
    levels = list(levels)
    levels[measured.pop()] = None
    low, high = measured[0], measured[-1]
    filled = list(levels)
    for i in range(low):
        filled[i] = levels[low] * i / low
    # Curve into white rather than running straight at it. A straight line puts a visible corner in
    # Contrast, the one control still near its peak deviation where the measurements stop (+1 peaks
    # at input 228 and +2 at 226, against Highlight's 205 and Midtone's 120), so the line has to
    # reverse a still-rising curve within a level. Everything else was already falling and barely
    # moves either way.
    span = 255 - high
    secant = (255 - levels[high]) / span
    back = measured[-9] if len(measured) > 8 else measured[0]
    # Leave at the slope actually measured, arrive at the secant slope, and clamp the leaving slope
    # into [0, 3*secant] - the Fritsch-Carlson band, which is what keeps the cubic monotonic. The
    # clamp is load-bearing: unclamped it dips Highlight +7, Contrast +2 and High Key.
    #
    # Arriving at the secant rather than parallel to the identity, because a parallel landing forces
    # the curve to plunge and then climb back - Contrast +2 reached slope 0.00 at input 240 and
    # recovered to 0.83 by 255, an S-bend that is an artefact of the constraint and not of anything
    # measured. Handing off to the average slope over the extension just declines, once.
    leaving = min(max((levels[high] - levels[back]) / (high - back), 0), 3 * secant)
    arriving = secant
    for i in range(high + 1, 256):
        t = (i - high) / span
        filled[i] = (
            (2 * t**3 - 3 * t**2 + 1) * levels[high]
            + (t**3 - 2 * t**2 + t) * leaving * span
            + (-2 * t**3 + 3 * t**2) * 255
            + (t**3 - t**2) * arriving * span
        )
    # Interior gaps are single levels the matcher could not populate; bridge them the same way.
    for a, b in zip(measured, measured[1:]):
        for i in range(a + 1, b):
            filled[i] = levels[a] + (levels[b] - levels[a]) * (i - a) / (b - a)
    return [float(value) for value in filled]


def read_run(path: Path) -> dict[str, list[float | None]]:
    """One export as {frame filename: 256 levels, None where unmeasured}."""
    with path.open() as handle:
        rows = list(csv.DictReader(handle))
    frames = [name for name in rows[0] if name != "input"]
    return {
        frame: [float(row[frame]) if row[frame] else None for row in rows]
        for frame in frames
    }


# Where the Swift table samples each curve. Sixteen-level spacing, plus 232 and 248 near white.
#
# The app joins these knots with straight lines, so what matters is not only how far the drawn curve
# sits from the measured one but how much its *slope* jumps at a knot - a value error spreads out
# invisibly, a slope jump is a corner you can see. Sixteen-level spacing costs 2.0 levels of value,
# comfortably inside the anchors' 2-level repeatability, and yet put an 0.87 slope break in
# Contrast +2 at knot 224, which is where the curve turns hardest into white. The two extra knots
# take that to 0.50, below the 0.57 that Shadow +7 has at input 32 from genuine measured curvature.
# Going denser than this stops helping: at 8-level spacing throughout the worst break is still 0.50.
KNOTS = sorted(set(list(range(0, 256, 16)) + [232, 248, 255]))

# The parser's own vocabulary, so a parsed CameraLook indexes this table without translation.
SWIFT_DIALS = {"Highlight": "HL", "Midtone": "Mid", "Shadow": "SH", "Contrast": "Contrast"}

SWIFT_HEADER = '''\
// Generated by scripts/label-tone-curves.py --swift from scripts/curves/tone-curve-table.csv.
// Re-run the script rather than editing by hand.

import Foundation

/// The in-camera tone curves, measured off real frames — see `scripts/README.md` "The measured
/// curves" for how, and `docs/SPEC.md` groups 3-6 for what the visualiser does with them.
///
/// Stored as *deviation from the identity* in output levels, not as absolute output, because that
/// is the form the composition rules want: the three tone dials compose by adding their deviations,
/// and a deviation of zero is a curve that did nothing. Sampled at `knots` and linearly
/// interpolated between them.
public enum CameraLookToneCurves {
    /// The input levels the samples sit at.
    public static let knots: [Int] = %s

    /// Deviation at each knot, by the parser's dial code and then the dialled value. Only the odd
    /// steps were shot; even ones interpolate, which the measured spacing supports (Midtone runs
    /// 8.2, 24.7, 41.8, 58.8 at +1/+3/+5/+7, so its steps are 16.5, 17.1, 17.0 apart).
    ///
    /// Deviation rather than absolute output is also what makes the knots sparse enough to read:
    /// every one of these numbers is a departure from the identity, so a run of zeros is a stretch
    /// the control genuinely left alone.
    public static let dials: [String: [Int: [Double]]] = [
%s    ]

    /// The Gradation presets, which are whole curves rather than a dial position. `Auto` is
    /// deliberately absent: it is a per-frame decision by the camera and has no fixed curve to draw.
    public static let gradationPresets: [String: [Double]] = [
%s    ]
}
'''


def emit_swift(table: dict[str, list[float]], path: Path) -> None:
    """Writes the table as a Swift source file, sampled at KNOTS and relative to the identity."""
    def samples(name: str) -> str:
        return "[" + ", ".join(f"{table[name][k] - k:.2f}" for k in KNOTS) + "]"

    dials: dict[str, list[str]] = {}
    for name in table:
        dial, _, value = name.rpartition(" ")
        if dial in SWIFT_DIALS:
            dials.setdefault(SWIFT_DIALS[dial], []).append(f"            {int(value)}: {samples(name)},")

    dial_lines = "".join(
        f'        "{code}": [\n' + "\n".join(sorted(lines, key=sort_value)) + "\n        ],\n"
        for code, lines in dials.items()
    )
    preset_lines = "".join(
        f'        "{name.lower()}": {samples(name)},\n'
        for name in table if name.rpartition(" ")[0] not in SWIFT_DIALS
    )
    path.write_text(SWIFT_HEADER % (KNOTS, dial_lines, preset_lines))
    print(f"wrote {path}")


def sort_value(line: str) -> int:
    return int(line.strip().split(":")[0])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("curves", type=Path, help="directory holding the per-run CSV exports")
    parser.add_argument("frames", type=Path, help="directory holding the JPEGs")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--swift", type=Path, default=None, help="also emit this Swift source file")
    args = parser.parse_args()

    table: dict[str, list[float]] = {}
    source: dict[str, str] = {}
    for run in RUNS:
        for frame, levels in read_run(args.curves / run).items():
            if frame in ANCHORS:
                continue
            name = label(read_settings(args.frames / frame))
            if name is None or name in table:
                continue
            table[name] = extend(levels)
            source[name] = frame

    output = args.output or args.curves / "tone-curve-table.csv"
    columns = sorted(table, key=sort_key)
    with output.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["input", *columns])
        for level in range(256):
            writer.writerow([level, *[f"{table[name][level]:.3f}" for name in columns]])

    print(f"wrote {output} with {len(columns)} curves")
    for name in columns:
        print(f"  {name:<14} {source[name]}")

    if args.swift:
        emit_swift(table, args.swift)


def sort_key(name: str) -> tuple[int, int, str]:
    """Dials in menu order and ascending value, with the gradation presets last."""
    order = ["Highlight", "Midtone", "Shadow", "Contrast"]
    dial, _, value = name.rpartition(" ")
    if dial not in order:
        return (len(order), 0, name)
    return (order.index(dial), int(value), name)


if __name__ == "__main__":
    main()
