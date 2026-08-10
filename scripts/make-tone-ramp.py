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

The ramp runs left to right with no border, markings or registration features, because
histogram matching does not care where anything sits in the frame - only what levels are
present. Being shot slightly crooked therefore costs nothing, and so does camera shake: blurring
a linear ramp with a symmetric kernel returns the same linear ramp away from its edges.

What it is *not* tolerant of is the camera moving between frames. The frame sits inside the
display, so a pan slides it along the ramp and changes which levels are in shot, which reads
back as a uniform level offset - indistinguishable from the light having changed. At 5120px for
255 levels that is 0.05 levels per pixel, so a 60px nudge invents a 3-level curve. The tripod
has to hold position across the whole run; it does not have to hold still during a frame.
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
