#!/usr/bin/env -S uv run --no-project --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "numpy", "scipy"]
# ///
"""Measures a Partial Color band profile from photos of make-hue-wheel.py.

Produced the I/II/III table in scripts/README.md. Give it the unfiltered reference frame
followed by the filtered ones:

    scripts/measure-partial-color.py REF.JPG FRAME.JPG [FRAME.JPG ...]

Measure chroma (max-min), not HSV saturation. Saturation is (max-min)/max, which inflates
wherever max is small, and blue is the dimmest hue a display renders - in saturation the
residual outside the band reads about twice its real size in the blues. The unfiltered
wheel's own chroma is nearly flat across hue (0.60-0.75), which is what makes dividing by
it a fair normalisation and rules out a dark-pixel artefact.
"""
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

SIZE = 2400.0          # make-hue-wheel.py's wheel, in its own pixel units
WHITE_DX = -148.0      # white hub patch centre, relative to wheel centre
PATCH_SEP = 264.0      # white to black patch centre distance
PATCH_SHAPE = 126.0 * 132.0 / PATCH_SEP ** 2  # patch area / separation^2, scale-free
BIN = 2.0              # degrees per angular bin
R_LO, R_HI = 0.26, 0.40  # radial sampling band, as a fraction of wheel width


def load(path, shrink=4):
    im = Image.open(path).convert("RGB")
    im = im.resize((im.width // shrink, im.height // shrink), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255.0


def blobs(mask, min_px=25):
    lab, n = ndimage.label(mask)
    found = []
    for i in range(1, n + 1):
        ys, xs = np.nonzero(lab == i)
        if ys.size >= min_px:
            found.append((np.array([xs.mean(), ys.mean()]), ys.size))
    return found


def geometry(rgb):
    """Centre, scale and rotation, from the two hub patches.

    The pair is chosen by matching the wheel's own area-to-separation ratio rather than by
    taking the brightest and darkest blobs: specular highlights on the display are routinely
    brighter than the white patch, and picking those silently rotates the whole measurement.
    """
    mx, mn = rgb.max(axis=2), rgb.min(axis=2)
    v = mx
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    neutral = sat < 0.30
    lo, hi = np.percentile(v[neutral], [1, 99])
    whites = blobs(neutral & (v > lo + 0.80 * (hi - lo)))
    blacks = blobs(neutral & (v < lo + 0.20 * (hi - lo)))

    best, score = None, np.inf
    for wc, wn in whites:
        for bc, bn in blacks:
            sep = np.linalg.norm(wc - bc)
            if sep < 10:
                continue
            err = (abs(wn / sep ** 2 - PATCH_SHAPE) + abs(bn / sep ** 2 - PATCH_SHAPE)
                   + 0.05 * abs(np.log(wn / bn)))
            if err < score:
                best, score = (wc, bc, sep), err
    if best is None:
        raise SystemExit("hub patches not found - is the whole wheel in frame?")

    white, black, sep = best
    scale = sep / PATCH_SEP
    axis = (black - white) / sep
    centre = white + axis * (-WHITE_DX * scale)
    return centre, scale, np.degrees(np.arctan2(axis[1], axis[0]))


def profile(path, quantile=0.75):
    """Retained chroma per angular bin. Bin angle equals displayed hue by the wheel's design."""
    rgb = load(path)
    chroma = rgb.max(axis=2) - rgb.min(axis=2)
    centre, scale, rot = geometry(rgb)

    h, w = chroma.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    dx, dy = xx - centre[0], yy - centre[1]
    t = np.radians(-rot)
    wx = dx * np.cos(t) - dy * np.sin(t)
    wy = dx * np.sin(t) + dy * np.cos(t)

    band = np.abs(np.hypot(wx, wy) / (scale * SIZE) - (R_LO + R_HI) / 2) <= (R_HI - R_LO) / 2
    ang = np.degrees(np.arctan2(wx, -wy)) % 360.0   # 0 at 12 o'clock, clockwise
    nb = int(360 / BIN)
    idx = (ang[band] / BIN).astype(int) % nb
    vals = chroma[band]

    prof = np.full(nb, np.nan)
    for b in range(nb):
        take = vals[idx == b]
        if take.size > 20:
            prof[b] = np.quantile(take, quantile)
    return prof, rot


def describe(prof):
    """Band centre, FWHM, 90-to-10% edge and out-of-band floor, normalised to the peak."""
    p = prof / np.nanmax(prof)
    ang = np.arange(len(p)) * BIN + BIN / 2
    off = (ang - ang[int(np.nanargmax(p))] + 180) % 360 - 180
    order = np.argsort(off)
    x, y = off[order], p[order]
    zero = int(np.argmin(np.abs(x)))

    def falls_to(frac, step):
        i = zero
        while 0 <= i + step < len(x) and y[i + step] >= frac:
            i += step
        return abs(x[i])

    kept = np.radians(ang[p >= 0.5])
    centre = np.degrees(np.arctan2(np.sin(kept).mean(), np.cos(kept).mean())) % 360
    edge = np.mean([falls_to(0.1, d) - falls_to(0.9, d) for d in (-1, 1)])
    return centre, falls_to(0.5, -1) + falls_to(0.5, 1), edge, np.nanmedian(y[np.abs(x) > 100])


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)

    ref, ref_rot = profile(sys.argv[1])
    print(f"reference {sys.argv[1].split('/')[-1]}: chroma median {np.nanmedian(ref):.3f}, "
          f"range {np.nanmin(ref):.3f}-{np.nanmax(ref):.3f}, rotation {ref_rot:+.2f} deg")
    print(f"\n{'frame':<16}{'centre':>8}{'FWHM':>7}{'edge 90-10%':>13}{'floor':>8}{'rot':>8}")
    for path in sys.argv[2:]:
        prof, rot = profile(path)
        centre, fwhm, edge, floor = describe(prof / ref)
        print(f"{path.split('/')[-1]:<16}{centre:8.1f}{fwhm:7.1f}{edge:13.1f}{floor:8.3f}"
              f"{rot:+8.2f}")
