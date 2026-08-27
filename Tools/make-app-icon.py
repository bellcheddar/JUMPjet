#!/usr/bin/env python3
"""Draw the app icon: an alpha helix with one segment mid-jump.

    Tools/coreml/.venv/bin/python Tools/make-app-icon.py

Why a helix and not the protein itself. The obvious icon for this app is a
backbone trace, and a real one was tried: at 1024 it is handsome and at 60,
which is the size an icon is actually looked at, a tangled Ca trace turns to
mush. An icon has to survive being small, so this is one bold helix, which is
the same subject reduced to a shape that still reads as a shape.

The palette is the app's: near-black night flight for the ground, phosphor green
for the helix, and one afterburner-amber segment, which is the colour a jump
event carries everywhere else in the interface. That amber turn is the whole
idea of the app in one mark: a structure, and one part of it moving.

Drawn at 4x and downsampled, because PIL has no antialiasing of its own and a
hard-edged icon looks cheap next to every other icon on the home screen.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

SIZE = 1024
SCALE = 4                      # supersampling factor
S = SIZE * SCALE

GROUND = (0x0A, 0x0E, 0x14)
PHOSPHOR = (0x00, 0xE6, 0x76)
AMBER = (0xFF, 0xB3, 0x00)
PANEL = (0x11, 0x18, 0x26)


def helix_points(turns: float, samples: int):
    """A helix seen side-on, as (x, y, depth) with depth in -1..1."""
    points = []
    for index in range(samples):
        t = index / (samples - 1)
        angle = t * turns * 2 * math.pi
        # x sweeps along the axis, y is the coil, depth says which strand is in
        # front so the ribbon can pass behind itself.
        x = -0.72 + 1.44 * t
        y = 0.40 * math.sin(angle)
        depth = math.cos(angle)
        points.append((x, y, depth))
    return points


def draw() -> Image.Image:
    image = Image.new("RGB", (S, S), GROUND)
    canvas = ImageDraw.Draw(image)

    # A soft panel glow behind the mark, so the icon is not a flat black square.
    glow = Image.new("RGB", (S, S), GROUND)
    ImageDraw.Draw(glow).ellipse(
        [S * 0.10, S * 0.10, S * 0.90, S * 0.90], fill=PANEL)
    image = Image.blend(image, glow.filter(ImageFilter.GaussianBlur(S // 12)), 0.85)
    canvas = ImageDraw.Draw(image)

    points = helix_points(turns=2.0, samples=1400)
    radius = int(S * 0.062)

    def to_pixels(point):
        x, y, _ = point
        # Rotate the whole mark slightly, so it reads as ascending rather than
        # lying flat: this is an app about motion.
        angle = math.radians(-16)
        rx = x * math.cos(angle) - y * math.sin(angle)
        ry = x * math.sin(angle) + y * math.cos(angle)
        return (S / 2 + rx * S * 0.44, S / 2 + ry * S * 0.44)

    # The amber segment: one stretch near the middle, which is the jump.
    jump_from, jump_to = 0.44, 0.60

    # Stamped discs rather than a thick polyline. PIL's wide `line` with
    # joint="curve" fans out spikes at every joint, which at icon scale looks
    # like a hatching artefact rather than a ribbon. Overlapping circles give
    # clean round caps and a constant width for nothing but more draw calls.
    #
    # Back strands first, then front, so the ribbon passes behind itself.
    for pass_index in (0, 1):
        for index, point in enumerate(points):
            behind = point[2] < 0
            if (pass_index == 0) != behind:
                continue
            t = index / (len(points) - 1)
            base = AMBER if jump_from <= t <= jump_to else PHOSPHOR
            # Depth cue: strands at the back are dimmer.
            shade = 0.42 if behind else 1.0
            colour = tuple(int(c * shade) for c in base)
            cx, cy = to_pixels(point)
            canvas.ellipse(
                [cx - radius, cy - radius, cx + radius, cy + radius], fill=colour)

    return image.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon = draw()
    icon.save(OUT, "PNG")
    # App Store rejects an icon with an alpha channel, and PIL will happily
    # write one if the mode ever changes.
    assert icon.mode == "RGB", f"icon must have no alpha, got {icon.mode}"
    print(f"wrote {OUT.relative_to(ROOT)}  {icon.size[0]}x{icon.size[1]}  {icon.mode}")

    # A quick legibility check: the mark has to survive being small.
    for size in (180, 120, 60):
        small = icon.resize((size, size), Image.LANCZOS)
        pixels = list(small.getdata())
        lit = sum(1 for p in pixels if sum(p) > 180)
        print(f"  at {size:>3}px: {lit * 100 // len(pixels)}% of pixels carry the mark")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
