#!/usr/bin/env python3
"""Generate Decelerate's macOS app icon into the asset catalog.

Design: a native macOS squircle with a deep blue gradient, a white pointer
arrow and fading "straight line" motion trails — the visual metaphor for
1:1 movement (no acceleration curve).

Rendered at 4x and downsampled with Lanczos for clean edges at every size.
Run:  python3 Scripts/generate-icon.py
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Decelerate" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
SUPERSAMPLE = 4
BASE = 1024


def squircle_mask(size: int, radius_ratio: float = 0.2237) -> Image.Image:
    """Approximate Apple's continuous-corner squircle with a rounded rect."""
    scale = 8
    big = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(big)
    r = int(size * radius_ratio * scale)
    draw.rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1), radius=r, fill=255
    )
    return big.resize((size, size), Image.LANCZOS)


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        img.putpixel(
            (0, y),
            (
                round(top[0] + (bottom[0] - top[0]) * t),
                round(top[1] + (bottom[1] - top[1]) * t),
                round(top[2] + (bottom[2] - top[2]) * t),
            ),
        )
    return img.resize((size, size), Image.BILINEAR)


def pointer_polygon(cx: float, cy: float, h: float) -> list[tuple[float, float]]:
    """Classic macOS arrow cursor, drawn from a unit outline scaled to h."""
    unit = [
        (0.00, 0.00), (0.00, 0.72), (0.175, 0.555), (0.345, 0.94),
        (0.485, 0.875), (0.315, 0.49), (0.565, 0.48),
    ]
    # Centre the outline's bounding box on (cx, cy).
    xs = [p[0] for p in unit]
    ys = [p[1] for p in unit]
    w = (max(xs) - min(xs)) * h
    hh = (max(ys) - min(ys)) * h
    ox = cx - w / 2 - min(xs) * h
    oy = cy - hh / 2 - min(ys) * h
    return [(ox + x * h, oy + y * h) for x, y in unit]


def render() -> Image.Image:
    s = BASE * SUPERSAMPLE
    icon = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # Background gradient: bright azure at the top, deep navy at the bottom.
    bg = vertical_gradient(s, (58, 134, 240), (17, 46, 104)).convert("RGBA")
    icon.paste(bg, (0, 0))

    # Soft radial sheen in the upper third, like Apple's icon lighting.
    sheen = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.ellipse(
        (-s * 0.25, -s * 0.55, s * 1.25, s * 0.62),
        fill=(255, 255, 255, 42),
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(s * 0.06))
    icon = Image.alpha_composite(icon, sheen)

    draw = ImageDraw.Draw(icon)

    # Motion trail: three evenly spaced dots along the cursor's straight path.
    # Equal spacing and equal size are the "constant gain" idea — the same
    # physical input always produces the same output, at any pointer speed.
    ux, uy = -0.7071, -0.7071  # unit vector the pointer travels along
    radius = 0.030 * s
    start = (0.600 * s, 0.610 * s)
    step = 0.104 * s
    for index in range(3):
        cx = start[0] - ux * step * index
        cy = start[1] - uy * step * index
        draw.ellipse(
            (cx - radius, cy - radius, cx + radius, cy + radius),
            fill=(255, 255, 255, 150 if index == 0 else 190),
        )

    # Pointer arrow with a soft drop shadow.
    arrow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    poly = pointer_polygon(0.430 * s, 0.395 * s, 0.520 * s)
    ad.polygon(poly, fill=(255, 255, 255, 255))
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon(
        [(x + 0.012 * s, y + 0.020 * s) for x, y in poly], fill=(6, 18, 40, 90)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(s * 0.012))
    icon = Image.alpha_composite(icon, shadow)
    icon = Image.alpha_composite(icon, arrow)

    # Subtle inner border for the squircle edge.
    edge = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    ed.rounded_rectangle(
        (2, 2, s - 3, s - 3), radius=int(0.2237 * s), outline=(255, 255, 255, 50), width=max(2, s // 340)
    )
    icon = Image.alpha_composite(icon, edge)

    # Apply the squircle mask.
    mask = squircle_mask(s)
    icon.putalpha(Image.composite(icon.getchannel("A"), Image.new("L", (s, s), 0), mask))
    return icon.resize((BASE, BASE), Image.LANCZOS)


SIZES = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

MAC_SLOTS = [
    ("16x16", "1x", "icon_16x16.png"), ("16x16", "2x", "icon_16x16@2x.png"),
    ("32x32", "1x", "icon_32x32.png"), ("32x32", "2x", "icon_32x32@2x.png"),
    ("128x128", "1x", "icon_128x128.png"), ("128x128", "2x", "icon_128x128@2x.png"),
    ("256x256", "1x", "icon_256x256.png"), ("256x256", "2x", "icon_256x256@2x.png"),
    ("512x512", "1x", "icon_512x512.png"), ("512x512", "2x", "icon_512x512@2x.png"),
]


def main() -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    master = render()
    for filename, size in SIZES:
        master.resize((size, size), Image.LANCZOS).save(ICONSET / filename)

    contents = {
        "images": [
            {"filename": fn, "idiom": "mac", "scale": scale, "size": size}
            for size, scale, fn in MAC_SLOTS
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"Wrote {len(SIZES)} icons to {ICONSET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
