#!/usr/bin/env python3
"""Generate the TokenMeter macOS app icon set.

macOS app icons are NOT full-bleed squares: they are a rounded "squircle"
(continuous-curvature superellipse) that sits inside the canvas with a
transparent margin, matching Finder/Safari/Mail. Shipping a full-bleed square
makes macOS (Tahoe / 26) wrap it in its own rounded tile with a background —
the "logo floating in a rectangle" look. This script renders the correct shape.

Design: graphite diagonal gradient body + a white gauge (ring + needle),
matching the menu-bar `gauge.with.needle` glyph.

Usage:  python3 scripts/generate_appicon.py
Output: Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png  (10 files)
"""

from __future__ import annotations

import math
import os

import numpy as np
from PIL import Image, ImageDraw

# Supersample resolution; every exported size is a Lanczos downscale of this.
S = 4096

# macOS icon grid: the squircle body spans ~80.5% of the canvas (100px margin
# on a 1024 canvas), leaving the transparent border every macOS icon has.
BODY_FRACTION = 0.805
SQUIRCLE_N = 5.0  # superellipse exponent → Apple-style continuous corners

# Graphite gradient (top-left → bottom-right), matching the app's dark UI.
GRAD_TOP_LEFT = (72, 72, 74)      # #48484A
GRAD_BOTTOM_RIGHT = (26, 26, 28)  # #1A1A1C

WHITE = (255, 255, 255, 255)

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Resources", "Assets.xcassets", "AppIcon.appiconset",
)

# (filename, pixel size)
TARGETS = [
    ("icon_16.png", 16),
    ("icon_16@2x.png", 32),
    ("icon_32.png", 32),
    ("icon_32@2x.png", 64),
    ("icon_128.png", 128),
    ("icon_128@2x.png", 256),
    ("icon_256.png", 256),
    ("icon_256@2x.png", 512),
    ("icon_512.png", 512),
    ("icon_512@2x.png", 1024),
]


def build_master() -> Image.Image:
    """Render the icon once at high resolution as an RGBA image."""
    # --- Diagonal graphite gradient --------------------------------------
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float64)
    t = (xx + yy) / (2.0 * (S - 1))  # 0 at top-left → 1 at bottom-right
    grad = np.empty((S, S, 3), dtype=np.float64)
    for c in range(3):
        grad[..., c] = GRAD_TOP_LEFT[c] + (GRAD_BOTTOM_RIGHT[c] - GRAD_TOP_LEFT[c]) * t
    rgb = np.clip(grad, 0, 255).astype(np.uint8)

    # --- Squircle (superellipse) alpha mask ------------------------------
    center = (S - 1) / 2.0
    a = (BODY_FRACTION * S) / 2.0  # half-extent of the body
    u = np.abs((xx - center) / a)
    v = np.abs((yy - center) / a)
    inside = (u ** SQUIRCLE_N + v ** SQUIRCLE_N) <= 1.0
    alpha = np.where(inside, 255, 0).astype(np.uint8)

    img = Image.fromarray(np.dstack([rgb, alpha]), mode="RGBA")

    # --- Gauge glyph (white), drawn on top -------------------------------
    draw = ImageDraw.Draw(img)
    c = center

    # Ring.
    outer_r = 0.300 * S
    stroke = 0.052 * S
    draw.ellipse(
        [c - outer_r, c - outer_r, c + outer_r, c + outer_r],
        outline=WHITE, width=int(round(stroke)),
    )

    # Needle: a teardrop pointing to ~10 o'clock (up and to the left) with a
    # sharp tip and a rounded hub — matching the menu-bar `gauge.with.needle`
    # SF Symbol's orientation so the two read as the same mark. (No dot at the
    # tip; the only rounding is the hub at the center.)
    angle = math.radians(-128)         # up-left; y-down coords: negative = up
    dx, dy = math.cos(angle), math.sin(angle)
    px, py = -dy, dx                    # perpendicular
    tip_len = 0.215 * S
    base_r = 0.060 * S
    bx, by = c - dx * 0.02 * S, c - dy * 0.02 * S   # hub sits at the center
    tx, ty = c + dx * tip_len, c + dy * tip_len     # sharp tip
    draw.polygon(
        [(bx + px * base_r, by + py * base_r),
         (tx, ty),
         (bx - px * base_r, by - py * base_r)],
        fill=WHITE,
    )
    draw.ellipse([bx - base_r, by - base_r, bx + base_r, by + base_r], fill=WHITE)

    return img


def main() -> None:
    master = build_master()
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, size in TARGETS:
        master.resize((size, size), Image.LANCZOS).save(os.path.join(OUT_DIR, name))
        print(f"  wrote {name} ({size}x{size})")
    print(f"Done → {OUT_DIR}")


if __name__ == "__main__":
    main()
