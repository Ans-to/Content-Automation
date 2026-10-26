#!/usr/bin/env python3
"""Generates the Android launcher icons for Content Automation.

Pure-Python (no Pillow dependency) so it runs anywhere. It renders:

* legacy square icons   -> android/app/src/main/res/mipmap-*/ic_launcher.png
* adaptive foregrounds  -> android/app/src/main/res/mipmap-*/ic_launcher_foreground.png
* a 512px source icon   -> assets/icon/app_icon.png

Design: rounded indigo→violet gradient tile, white "play" triangle and a small
amber clock badge (video + schedule).

Usage:  python3 tool/generate_icons.py
"""
from __future__ import annotations

import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

# Android density buckets -> (legacy icon px, adaptive foreground px)
DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}

SUPERSAMPLE = 3  # anti-aliasing factor

GRAD_TOP = (79, 70, 229)      # indigo-600
GRAD_BOTTOM = (124, 58, 237)  # violet-600
WHITE = (255, 255, 255)
AMBER = (251, 191, 36)
AMBER_DARK = (180, 83, 9)


def write_png(path: str, width: int, height: int, pixels: list[list[tuple[int, int, int, int]]]) -> None:
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter type: none
        for r, g, b, a in row:
            raw.extend((r, g, b, a))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(png)


# --- geometry helpers (all in unit coordinates 0..1) ---------------------------------

def in_rounded_rect(x: float, y: float, inset: float, radius: float) -> bool:
    lo, hi = inset, 1.0 - inset
    if x < lo or x > hi or y < lo or y > hi:
        return False
    cx = min(max(x, lo + radius), hi - radius)
    cy = min(max(y, lo + radius), hi - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2


def in_triangle(px: float, py: float, a, b, c) -> bool:
    def sign(p1, p2, p3):
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])

    d1 = sign((px, py), a, b)
    d2 = sign((px, py), b, c)
    d3 = sign((px, py), c, a)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def in_circle(x: float, y: float, cx: float, cy: float, r: float) -> bool:
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_segment(x: float, y: float, x1: float, y1: float, x2: float, y2: float, half_w: float) -> bool:
    dx, dy = x2 - x1, y2 - y1
    length_sq = dx * dx + dy * dy
    t = 0.0 if length_sq == 0 else max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / length_sq))
    nx, ny = x1 + t * dx, y1 + t * dy
    return (x - nx) ** 2 + (y - ny) ** 2 <= half_w * half_w


def glyph_color(x: float, y: float, scale: float, ox: float, oy: float):
    """Returns the glyph colour at unit coords (x, y) or None.

    The glyph (triangle + clock badge) is designed in a 0..1 box and then
    scaled by `scale` around the centre (0.5, 0.5) with an offset (ox, oy).
    """
    # map back into glyph design space
    gx = (x - 0.5 - ox) / scale + 0.5
    gy = (y - 0.5 - oy) / scale + 0.5

    # clock badge (bottom-right)
    bcx, bcy, br = 0.74, 0.74, 0.17
    if in_circle(gx, gy, bcx, bcy, br):
        if in_circle(gx, gy, bcx, bcy, br - 0.035):
            # hands
            if in_segment(gx, gy, bcx, bcy, bcx, bcy - 0.085, 0.018) or in_segment(
                gx, gy, bcx, bcy, bcx + 0.065, bcy, 0.018
            ):
                return AMBER_DARK
            return AMBER
        return WHITE  # badge ring

    # play triangle (slightly right of centre for optical balance)
    tri = ((0.32, 0.24), (0.32, 0.76), (0.76, 0.50))
    if in_triangle(gx, gy, *tri):
        return WHITE
    return None


def render(size: int, *, legacy: bool) -> list[list[tuple[int, int, int, int]]]:
    """Renders the icon at `size` px.

    legacy=True  -> rounded gradient tile with the glyph (classic launcher icon)
    legacy=False -> transparent adaptive-icon foreground; glyph fits the
                    66/108 safe zone and the background colour is supplied by
                    the adaptive icon XML.
    """
    ss = SUPERSAMPLE
    big = size * ss
    out: list[list[tuple[int, int, int, int]]] = []
    for py in range(size):
        row: list[tuple[int, int, int, int]] = []
        for px in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    x = (px * ss + sx + 0.5) / big
                    y = (py * ss + sy + 0.5) / big
                    color = None
                    alpha = 0
                    if legacy:
                        if in_rounded_rect(x, y, 0.02, 0.22):
                            t = y
                            bg = tuple(
                                int(GRAD_TOP[i] * (1 - t) + GRAD_BOTTOM[i] * t) for i in range(3)
                            )
                            color = glyph_color(x, y, 0.78, 0.0, 0.0) or bg
                            alpha = 255
                    else:
                        color = glyph_color(x, y, 0.50, 0.0, 0.0)
                        alpha = 255 if color else 0
                    if color:
                        acc[0] += color[0]
                        acc[1] += color[1]
                        acc[2] += color[2]
                    acc[3] += alpha
            n = ss * ss
            a = acc[3] // n
            if acc[3] == 0:
                row.append((0, 0, 0, 0))
            else:
                # un-premultiply: average colour over covered samples only
                covered = acc[3] // 255
                row.append((acc[0] // covered, acc[1] // covered, acc[2] // covered, a))
        out.append(row)
    return out


def main() -> None:
    for density, (legacy_px, fg_px) in DENSITIES.items():
        folder = os.path.join(RES, f"mipmap-{density}")
        write_png(os.path.join(folder, "ic_launcher.png"), legacy_px, legacy_px, render(legacy_px, legacy=True))
        write_png(
            os.path.join(folder, "ic_launcher_foreground.png"),
            fg_px,
            fg_px,
            render(fg_px, legacy=False),
        )
        print(f"wrote mipmap-{density}: {legacy_px}px legacy, {fg_px}px foreground")

    source = os.path.join(ROOT, "assets", "icon", "app_icon.png")
    write_png(source, 512, 512, render(512, legacy=True))
    print(f"wrote {os.path.relpath(source, ROOT)}")


if __name__ == "__main__":
    main()
