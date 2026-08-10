#!/usr/bin/env -S uv run --no-project --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "numpy"]
# ///
"""Generates the grey ramp used to measure the in-camera tone curve - see scripts/README.md.

A smooth ramp rather than a step wedge or a real scene, because of how the measurement works:
`measure-tone-curve.py` matches cumulative histograms, so it can only recover the curve at
levels the reference frame actually contains, and only where each is populated by more than a
ten-thousandth of the frame. A step wedge leaves the levels between its patches empty and a
real scene leaves them lumpy - both show up as unmeasured gaps in the middle of the curve. A
ramp populates all 256 levels evenly by construction.

Neutral by construction too (R=G=B at every column), which is what makes the measurement's
per-channel spread reading meaningful: any difference between the recovered R, G and B curves
came from the camera, because there was none in the target.

The ramp runs left to right with no border, markings or registration features. It needs none -
histogram matching does not care where anything is in the frame, only what levels are present,
so unlike the hue wheel this target survives being shot freehand and slightly crooked.
"""
import argparse

import numpy as np
from PIL import Image


def build(width: int, height: int) -> Image.Image:
    """A linear black-to-white ramp, full bleed.

    Linear in stored code value, not in light: the curve worth measuring maps stored level to
    stored level, so the target's levels are what must be evenly spread. Whatever gamma the
    display then applies is harmless - it reshapes how many pixels land on each captured level,
    but not which captured level a given scene tone maps to, and the reference and test frames
    go through it identically.
    """
    ramp = np.rint(np.linspace(0, 255, width)).astype(np.uint8)
    return Image.fromarray(np.tile(ramp, (height, 1))).convert("RGB")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", help="PNG to write")
    parser.add_argument("--width", type=int, default=2560)
    parser.add_argument("--height", type=int, default=1440)
    args = parser.parse_args()

    build(args.width, args.height).save(args.output)
    print(f"wrote {args.output} ({args.width}x{args.height})")


if __name__ == "__main__":
    main()
