#!/usr/bin/env -S uv run --no-project --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "numpy"]
# ///
"""Generates the hue wheel used to measure the Partial Color ring — see scripts/README.md.

The wheel is a continuous hue sweep by angle, so whatever band the camera keeps, that hue is
present. 0 degrees sits at 12 o'clock and hue increases clockwise, which makes the surviving
sector's position readable geometrically rather than from its colour — the measurement is then
immune to the display's gamut and the camera's white balance, both of which would otherwise
make photographing a monitor useless.

The two hub patches and the orientation notch exist for registration: the white and black
patch centres sit at known offsets from the wheel centre, so a photo of the wheel yields its
own centre, scale and rotation without assuming anything about how it was framed.
"""
import colorsys
import sys

import numpy as np
from PIL import Image, ImageDraw

SIZE = 2400
CENTRE = SIZE // 2
OUTER = int(SIZE * 0.46)
INNER = int(SIZE * 0.20)
PATCH = int(SIZE * 0.055)


def build() -> Image.Image:
    y, x = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    radius = np.hypot(x - CENTRE, y - CENTRE)
    angle = np.degrees(np.arctan2(x - CENTRE, -(y - CENTRE))) % 360

    hues = (angle / 360.0).reshape(-1)
    rgb = np.array([colorsys.hsv_to_rgb(h, 1.0, 1.0) for h in hues], dtype=np.float32)
    img = (rgb.reshape(SIZE, SIZE, 3) * 255).astype(np.uint8)
    img[(radius > OUTER) | (radius < INNER)] = 128  # neutral surround: only the ring carries colour

    im = Image.fromarray(img)
    draw = ImageDraw.Draw(im)

    # White / mid grey / black at the hub. The outer two are the registration landmarks; the mid
    # grey doubles as a white-balance reference and deliberately matches the surround.
    for i, tone in enumerate((255, 128, 0)):
        left = CENTRE - int(PATCH * 1.6) + i * PATCH
        draw.rectangle([left, CENTRE - PATCH // 2, left + PATCH - 6, CENTRE + PATCH // 2],
                       fill=(tone, tone, tone))

    draw.polygon([(CENTRE, INNER - 10), (CENTRE - 34, INNER - 90), (CENTRE + 34, INNER - 90)],
                 fill=(255, 255, 255), outline=(0, 0, 0))
    return im


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "hue-wheel.png"
    build().save(out)
    print(f"wrote {out}  {SIZE}x{SIZE}  ring radius {INNER}-{OUTER}px")
