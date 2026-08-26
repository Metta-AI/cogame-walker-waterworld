#!/usr/bin/env python3
"""Key, split and pad the nano-banana board-art sheets into board sprites.

The sheets under `scripts/art/source/` are Gemini (`gemini-2.5-flash-image`)
renders of the Softmax cog rebuilt as waterworld's characters — one kit per
role, so the four skimmers and the two particle kinds read apart at board scale
with every label hidden (playbooks/art-nanobanana.md). Gemini returns no alpha
and the "pure green" backdrop comes back as *some* green with a tinted edge, so
the backdrop is keyed by a flood fill from the border with the border's MEDIAN
colour as the key — green accents inside a character survive that, a corner
smudge does not shift it.

    python3 scripts/art/split_sheet.py

Writes, at the sizes src/waterworld/global.nim blits them at (2x the logical
board pixel, RenderScale):

    data/art/skim_1.png .. skim_4.png   96x96   one kit per skimmer
    data/art/plankton.png               64x64
    data/art/poison.png                 64x64
    data/art/rock.png                  360x360

Nothing else in the repo generates art: there is no procedural rig fallback in
the tree, and CI never regenerates these files — the derived PNGs are committed
next to their source sheets.
"""

from __future__ import annotations

import os
import sys
from collections import deque

try:
    from PIL import Image
except ImportError:  # pragma: no cover - dependency hint only
    sys.exit("pillow is required: python3 -m pip install --user pillow")

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(REPO, "scripts", "art", "source")
OUT = os.path.join(REPO, "data", "art")

# sheet file -> [(output name, output size), ... left to right]
SHEETS = [
    (
        "skimmers_sheet.png",
        [("skim_1", 96), ("skim_2", 96), ("skim_3", 96), ("skim_4", 96)],
    ),
    (
        "particles_sheet.png",
        [("plankton", 64), ("poison", 64), ("rock", 360)],
    ),
]

# How far from the border key a pixel may sit and still count as backdrop. The
# renders come back with a soft anti-aliased rim, so a tight threshold leaves a
# green halo and a loose one eats the mint-green plankton.
KEY_TOLERANCE = 62


def border_median(image: Image.Image) -> tuple[int, int, int]:
    """The backdrop colour: the median of the whole one-pixel border."""
    px = image.load()
    w, h = image.size
    reds, greens, blues = [], [], []
    for x in range(w):
        for y in (0, h - 1):
            r, g, b = px[x, y][:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    for y in range(h):
        for x in (0, w - 1):
            r, g, b = px[x, y][:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    reds.sort()
    greens.sort()
    blues.sort()
    mid = len(reds) // 2
    return reds[mid], greens[mid], blues[mid]


def key_backdrop(image: Image.Image) -> Image.Image:
    """Flood-fill the backdrop to transparent from every border pixel."""
    image = image.convert("RGBA")
    w, h = image.size
    px = image.load()
    key = border_median(image)
    seen = bytearray(w * h)
    queue: deque[tuple[int, int]] = deque()

    def near_key(x: int, y: int) -> bool:
        r, g, b, _ = px[x, y]
        return (
            abs(r - key[0]) + abs(g - key[1]) + abs(b - key[2])
        ) <= KEY_TOLERANCE

    for x in range(w):
        for y in (0, h - 1):
            queue.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            queue.append((x, y))

    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= w or y >= h:
            continue
        index = y * w + x
        if seen[index]:
            continue
        seen[index] = 1
        if not near_key(x, y):
            continue
        px[x, y] = (0, 0, 0, 0)
        queue.append((x + 1, y))
        queue.append((x - 1, y))
        queue.append((x, y + 1))
        queue.append((x, y - 1))
    return image


def occupied_columns(image: Image.Image) -> list[bool]:
    w, h = image.size
    px = image.load()
    out = []
    for x in range(w):
        hit = False
        for y in range(h):
            if px[x, y][3] > 24:
                hit = True
                break
        out.append(hit)
    return out


def split_row(image: Image.Image, count: int) -> list[Image.Image]:
    """Cut the row on empty columns, widest `count` runs kept, left to right."""
    columns = occupied_columns(image)
    runs = []
    start = None
    for x, hit in enumerate(columns):
        if hit and start is None:
            start = x
        elif not hit and start is not None:
            runs.append((start, x - 1))
            start = None
    if start is not None:
        runs.append((start, len(columns) - 1))
    if len(runs) < count:
        raise SystemExit(
            f"expected {count} objects on the sheet, found {len(runs)} column runs"
        )
    runs.sort(key=lambda r: r[1] - r[0], reverse=True)
    runs = sorted(runs[:count])
    parts = []
    for x0, x1 in runs:
        band = image.crop((x0, 0, x1 + 1, image.size[1]))
        parts.append(band.crop(band.getbbox()))
    return parts


def pad_square(image: Image.Image, size: int) -> Image.Image:
    w, h = image.size
    side = max(w, h)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(image, ((side - w) // 2, (side - h) // 2))
    return square.resize((size, size), Image.LANCZOS)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for sheet, wanted in SHEETS:
        path = os.path.join(SOURCE, sheet)
        keyed = key_backdrop(Image.open(path))
        parts = split_row(keyed, len(wanted))
        for part, (name, size) in zip(parts, wanted):
            out = os.path.join(OUT, name + ".png")
            pad_square(part, size).save(out)
            print(f"{sheet}: {name}.png {size}x{size}")


if __name__ == "__main__":
    main()
