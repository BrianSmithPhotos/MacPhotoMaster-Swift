#!/usr/bin/env -S uv run --no-project --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "numpy"]
# ///
"""Measures an in-camera tone curve from a neutral reference frame and one frame per setting.

    scripts/measure-tone-curve.py REF.JPG FRAME.JPG [FRAME.JPG ...]
    scripts/measure-tone-curve.py --csv curves.csv REF.JPG FRAME.JPG ...
    scripts/measure-tone-curve.py --compose REF.JPG A.JPG B.JPG AB.JPG

Recovers the curve by matching cumulative histograms, not by pairing pixels: T(x) is the
test level whose cumulative histogram equals the reference's at x. Two frames of the same
scene at the same exposure are all it needs, and it is immune to the small framing shifts a
tripod still allows - pixel pairing would fold those into the curve as noise, worst exactly
where the scene has edges. The cost is that it assumes the mapping is a monotonic *global*
function of level, which is why Gradation Auto cannot be measured this way at all: it is a
scene-adaptive operator, and there is no single curve there to find.

Works in the JPEG's own encoding rather than linearising first. The curve worth drawing is
the one from stored level to stored level, because that is the one the viewer sees.

--compose answers the question the whole model depends on: whether Highlight, Midtone and
Shadow are three independent pivots on one curve or interact with each other. Shoot A alone,
B alone, and the two together, and this reports whether the combined frame matches B applied
after A. If it does, the visualiser can compose three measured basis curves; if it does not,
the settings need measuring on a grid.
"""
import argparse

import numpy as np
from PIL import Image

LEVELS = 256
LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)
REPORT_AT = (16, 32, 64, 96, 128, 160, 192, 224, 240)
# Fraction of the frame a level needs before its mapping counts as measured rather than guessed.
FLOOR = 1e-4
# Fraction of the reference allowed to sit hard against black or white before the run is unusable.
CLIPPED = 5e-3
# Levels of disagreement below which two settings are called independent. Under 1% of the range,
# and comfortably under a JPEG quantisation step in the midtones.
INDEPENDENT = 3.0


def channels(path, step):
    """R, G, B and luma planes, subsampled by plain decimation.

    Decimation rather than a resampling filter: every filter averages neighbours, and averaging
    then curving is not the same as curving then averaging, so a resize quietly reshapes the very
    histogram this measurement reads.
    """
    rgb = np.asarray(Image.open(path).convert("RGB"))[::step, ::step].astype(np.float32)
    return [rgb[..., 0], rgb[..., 1], rgb[..., 2], rgb @ LUMA]


def histograms(path, step):
    return [
        np.bincount(
            np.clip(np.rint(plane), 0, LEVELS - 1).astype(np.int32).ravel(), minlength=LEVELS
        ).astype(np.float64)
        for plane in channels(path, step)
    ]


def transfer(reference, test):
    """Output level per input level, NaN where the reference scene cannot constrain it."""
    ref, tst = reference / reference.sum(), test / test.sum()
    curve = np.interp(np.cumsum(ref), np.cumsum(tst), np.arange(LEVELS, dtype=np.float64))
    curve[ref < FLOOR] = np.nan
    return curve


def compose(first, second):
    """second(first(x)) - the curve two settings give if they act independently, in series."""
    return np.interp(first, np.arange(LEVELS, dtype=np.float64), second)


def measured_range(curve):
    defined = np.flatnonzero(~np.isnan(curve))
    return (defined[0], defined[-1]) if defined.size else (0, 0)


def deviation(curve):
    """Furthest the curve strays from the identity diagonal, and the input level it happens at."""
    offset = curve - np.arange(LEVELS, dtype=np.float64)
    if np.all(np.isnan(offset)):
        return 0.0, 0
    at = int(np.nanargmax(np.abs(offset)))
    return offset[at], at


def channel_spread(curves):
    """Widest disagreement between the R, G and B curves at any one input level.

    A setting applied to luminance moves all three together and reads low; one applied per channel
    reads several times higher, and a single grey curve would then be the wrong graphic. Read it by
    comparing frames rather than against zero: the channels cover different parts of the scene's
    range, so even a common curve leaves some spread where one channel's tones run out.
    """
    stack = np.array(curves[:3])
    # Only levels all three channels reach: a level one channel never sees says nothing about
    # whether they agree, and differencing against its NaN would drop the whole comparison.
    stack = stack[:, ~np.isnan(stack).any(axis=0)]
    if not stack.size:
        return 0.0
    return float(np.max(stack.max(axis=0) - stack.min(axis=0)))


def clipping(histogram):
    """Fraction of the frame sitting hard at black and at white.

    Checked on the reference because clipping there is unrecoverable, not merely noisy: once a range
    of scene tones has been flattened onto level 0 or 255, the cumulative histogram has a step at
    that end and nothing can say which input level a test frame's tones came from. A setting that
    lifts shadows is then measured against a reference that has already thrown the shadows away.
    """
    total = histogram.sum()
    return histogram[0] / total, histogram[-1] / total


def name(path):
    return path.split("/")[-1]


def report(paths, curves, spreads):
    header = "".join(f"{level:>6}" for level in REPORT_AT)
    print(f"\n{'frame':<22}{header}{'max dev':>10}{'chan':>7}{'tones':>12}")
    for path, curve, spread in zip(paths, curves, spreads):
        row = "".join(
            f"{curve[level]:6.1f}" if not np.isnan(curve[level]) else f"{'-':>6}"
            for level in REPORT_AT
        )
        offset, at = deviation(curve)
        lo, hi = measured_range(curve)
        print(f"{name(path):<22}{row}{offset:+7.1f}@{at:<3}{spread:7.2f}{f'{lo}-{hi}':>12}")


def report_composition(paths, curves):
    """Test the two ways two settings might combine, and report which the frames support.

    Serial: the camera applies one curve then the other. Additive: each setting displaces the
    curve from the diagonal and the displacements sum, which is what a control that nudges spline
    control points and re-splines would do. Both are reported because the second is the more
    plausible mechanism but the first is the one that is easy to state, and picking either a
    priori would decide the result by assumption rather than by measurement.
    """
    a, b, ab = curves
    x = np.arange(LEVELS, dtype=np.float64)
    models = {
        "serial a-then-b": compose(a, b) - ab,
        "serial b-then-a": compose(b, a) - ab,
        "additive offset": (a - x) + (b - x) - (ab - x),
    }

    print(f"\ncomposition: how do {name(paths[0])} and {name(paths[1])} make {name(paths[2])}?")
    best, best_max = None, np.inf
    for label, error in models.items():
        usable = ~np.isnan(error)
        rms = float(np.sqrt(np.mean(error[usable] ** 2)))
        at = int(np.nanargmax(np.abs(error)))
        # Mean error is reported alongside rms because a one-signed bias is the signature of
        # something drifting between frames, while a genuine interaction wanders either side of
        # zero. They are diagnosed differently and the rms alone hides the difference.
        print(
            f"  {label:16} rms {rms:6.2f}  max {error[at]:+7.2f} at {at:<4}"
            f" mean {float(np.mean(error[usable])):+7.2f}"
        )
        if abs(error[at]) < best_max:
            best, best_max = label, abs(error[at])

    lo, hi = measured_range(models[best])
    print(f"  over levels {lo}-{hi}")
    if best_max < INDEPENDENT:
        print(f"  -> independent, as {best} (threshold {INDEPENDENT:.0f} levels)")
    else:
        print(f"  -> INTERACTING under every model, best was {best} (threshold {INDEPENDENT:.0f})")
        print("     before believing that, check the repeat reference: a one-signed mean error")
        print("     means something drifted between frames and the run cannot answer this")


def write_csv(path, paths, curves):
    with open(path, "w") as out:
        out.write("input," + ",".join(name(p) for p in paths) + "\n")
        for level in range(LEVELS):
            values = ",".join(
                "" if np.isnan(curve[level]) else f"{curve[level]:.3f}" for curve in curves
            )
            out.write(f"{level},{values}\n")
    print(f"\nwrote {path}")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("reference", help="the all-neutral frame every curve is measured against")
    parser.add_argument("frames", nargs="+")
    parser.add_argument("--step", type=int, default=2, help="decimate by this factor (default 2)")
    parser.add_argument("--csv", help="write the full 256-level curves here")
    parser.add_argument(
        "--compose", action="store_true", help="treat the frames as A B AB and test independence"
    )
    args = parser.parse_args()

    if args.compose and len(args.frames) != 3:
        raise SystemExit("--compose needs exactly three frames: A, B, then the two together")

    reference = histograms(args.reference, args.step)
    curves, spreads = [], []
    for path in args.frames:
        test = histograms(path, args.step)
        frame = [transfer(r, t) for r, t in zip(reference, test)]
        curves.append(frame[3])
        spreads.append(channel_spread(frame))

    lo, hi = measured_range(curves[0])
    black, white = clipping(reference[3])
    print(f"reference {name(args.reference)}: scene covers levels {lo}-{hi}")
    print(f"  clipped {black * 100:.2f}% at black, {white * 100:.2f}% at white")
    if hi - lo < 180:
        print("  warning: a scene this flat leaves most of the curve unmeasured - shoot wider")
    if max(black, white) > CLIPPED:
        print("  warning: the reference is clipped - reshoot it, no curve can be recovered there")

    report(args.frames, curves, spreads)
    if args.compose:
        report_composition(args.frames, curves)
    if args.csv:
        write_csv(args.csv, args.frames, curves)


if __name__ == "__main__":
    main()
