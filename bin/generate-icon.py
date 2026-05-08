#!/usr/bin/env python3
"""
Generate Pacer's app icon.

Authoring source is the SVG written below. We render to a 1024×1024 PNG
with rsvg-convert, then downsize via `sips` to every macOS app-icon
slot. Output goes straight into App/Assets.xcassets/AppIcon.appiconset/.

Concept: a stylized speedometer/pace gauge — matches the
`gauge.with.dots.needle.*` SF Symbol family the menu bar uses, and
echoes the app's central "pace" abstraction. Sweep gradient runs
green → yellow → orange (the same UsageBand palette the dashboard's
gauges use), needle parked around 60% so it reads as "in motion" not
"maxed out". Background is a confident indigo→cyan gradient.

Re-run any time the design changes:
    python3 bin/generate-icon.py
"""

from __future__ import annotations

import math
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ASSET_DIR = REPO / "App" / "Assets.xcassets" / "AppIcon.appiconset"
SVG_OUT = REPO / "bin" / "icon.svg"
PNG_1024 = ASSET_DIR / "icon_512x512@2x.png"  # canonical full-res render

SIZE = 1024
CORNER_RADIUS = 226  # ≈22% — close to Apple's continuous-corner mask

# Gauge geometry
GCX = SIZE / 2
GCY = SIZE * 0.575          # nudged below visual center so the open-bottom arc balances
GR = 322                    # gauge radius
GAUGE_THICKNESS = 90
START_DEG = 220             # math degrees (0=right, 90=up); 220° ≈ 7-o'clock
END_DEG = -40               # 320° ≈ 5-o'clock; total sweep 260°
ACTIVE_FRACTION = 0.62      # needle parked in the orange band

# Needle
NEEDLE_LEN = GR - 18
NEEDLE_BASE_HALF = 30


def deg_to_xy(cx: float, cy: float, r: float, deg: float) -> tuple[float, float]:
    """Math-convention degrees (0=right, 90=up) → SVG screen coords."""
    rad = math.radians(deg)
    return (cx + r * math.cos(rad), cy - r * math.sin(rad))


def arc_clockwise(cx: float, cy: float, r: float,
                  start_deg: float, end_deg: float) -> str:
    """SVG path string for a clockwise (visually) arc from start_deg to end_deg."""
    delta = (start_deg - end_deg) % 360 or 360
    large_arc = 1 if delta > 180 else 0
    sweep = 1  # sweep-flag=1 = clockwise on screen (math angle decreasing under y-flip)
    sx, sy = deg_to_xy(cx, cy, r, start_deg)
    ex, ey = deg_to_xy(cx, cy, r, end_deg)
    return f"M {sx:.2f} {sy:.2f} A {r} {r} 0 {large_arc} {sweep} {ex:.2f} {ey:.2f}"


def build_svg() -> str:
    total_deg = (START_DEG - END_DEG) % 360
    active_end_deg = START_DEG - ACTIVE_FRACTION * total_deg

    track = arc_clockwise(GCX, GCY, GR, START_DEG, END_DEG)
    active = arc_clockwise(GCX, GCY, GR, START_DEG, active_end_deg)

    # Needle as a tapered triangle: base centered on (GCX, GCY), tip at active_end_deg.
    tip = deg_to_xy(GCX, GCY, NEEDLE_LEN, active_end_deg)
    perp = math.radians(active_end_deg) + math.pi / 2
    bdx = NEEDLE_BASE_HALF * math.cos(perp)
    bdy = -NEEDLE_BASE_HALF * math.sin(perp)
    base_l = (GCX + bdx, GCY + bdy)
    base_r = (GCX - bdx, GCY - bdy)

    # Tick marks at 5 evenly-spaced positions along the arc, sitting just outside the gauge stroke.
    tick_inner_r = GR + GAUGE_THICKNESS / 2 + 22
    tick_outer_r = GR + GAUGE_THICKNESS / 2 + 56
    ticks: list[str] = []
    n_ticks = 5
    for i in range(n_ticks):
        frac = i / (n_ticks - 1)
        deg = START_DEG - frac * total_deg
        ix, iy = deg_to_xy(GCX, GCY, tick_inner_r, deg)
        ox, oy = deg_to_xy(GCX, GCY, tick_outer_r, deg)
        ticks.append(
            f'<line x1="{ix:.1f}" y1="{iy:.1f}" x2="{ox:.1f}" y2="{oy:.1f}" '
            f'stroke="#FFFFFF" stroke-opacity="0.55" stroke-width="11" stroke-linecap="round"/>'
        )

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="{SIZE}" y2="{SIZE}" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#6E45E2"/>
      <stop offset="55%" stop-color="#3B82F6"/>
      <stop offset="100%" stop-color="#00C6FB"/>
    </linearGradient>
    <linearGradient id="topGloss" x1="0" y1="0" x2="0" y2="{SIZE * 0.55:.0f}" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.22"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="gaugeSweep" x1="{GCX - GR:.0f}" y1="{GCY:.0f}" x2="{GCX + GR:.0f}" y2="{GCY:.0f}" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#34D158"/>
      <stop offset="55%" stop-color="#FFCC00"/>
      <stop offset="100%" stop-color="#FF9500"/>
    </linearGradient>
    <radialGradient id="centerCap" cx="50%" cy="40%" r="60%">
      <stop offset="0%" stop-color="#FFFFFF"/>
      <stop offset="100%" stop-color="#E0E8FF"/>
    </radialGradient>
    <filter id="needleShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="11"/>
      <feOffset dx="0" dy="6"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.45"/></feComponentTransfer>
      <feMerge>
        <feMergeNode/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
  </defs>

  <!-- Background squircle + glossy top highlight -->
  <rect x="0" y="0" width="{SIZE}" height="{SIZE}" rx="{CORNER_RADIUS}" ry="{CORNER_RADIUS}" fill="url(#bg)"/>
  <rect x="0" y="0" width="{SIZE}" height="{SIZE}" rx="{CORNER_RADIUS}" ry="{CORNER_RADIUS}" fill="url(#topGloss)"/>

  <!-- Tick marks -->
  {chr(10).join("  " + t for t in ticks)}

  <!-- Gauge track -->
  <path d="{track}" fill="none" stroke="#FFFFFF" stroke-opacity="0.20"
        stroke-width="{GAUGE_THICKNESS}" stroke-linecap="round"/>

  <!-- Active sweep -->
  <path d="{active}" fill="none" stroke="url(#gaugeSweep)"
        stroke-width="{GAUGE_THICKNESS}" stroke-linecap="round"/>

  <!-- Needle (with subtle drop shadow) -->
  <g filter="url(#needleShadow)">
    <polygon points="{base_l[0]:.2f},{base_l[1]:.2f} {tip[0]:.2f},{tip[1]:.2f} {base_r[0]:.2f},{base_r[1]:.2f}"
             fill="#FFFFFF"/>
  </g>

  <!-- Center cap -->
  <circle cx="{GCX:.0f}" cy="{GCY:.0f}" r="38" fill="url(#centerCap)"/>
  <circle cx="{GCX:.0f}" cy="{GCY:.0f}" r="14" fill="#3B82F6"/>
</svg>
"""


# ----- macOS app icon slots -----

# (filename, pixel size). All marked idiom=mac in Contents.json.
SLOTS: list[tuple[str, int, str]] = [
    ("icon_16x16.png",       16,  "16x16@1x"),
    ("icon_16x16@2x.png",    32,  "16x16@2x"),
    ("icon_32x32.png",       32,  "32x32@1x"),
    ("icon_32x32@2x.png",    64,  "32x32@2x"),
    ("icon_128x128.png",     128, "128x128@1x"),
    ("icon_128x128@2x.png",  256, "128x128@2x"),
    ("icon_256x256.png",     256, "256x256@1x"),
    ("icon_256x256@2x.png",  512, "256x256@2x"),
    ("icon_512x512.png",     512, "512x512@1x"),
    ("icon_512x512@2x.png",  1024, "512x512@2x"),
]


def write_contents_json(path: Path) -> None:
    import json

    images = []
    for filename, _px, slot in SLOTS:
        size, scale = slot.split("@")
        images.append({
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": size,
        })
    payload = {
        "images": images,
        "info": {"author": "xcode", "version": 1},
    }
    path.write_text(json.dumps(payload, indent=2) + "\n")


def main() -> int:
    if shutil.which("rsvg-convert") is None:
        print("error: rsvg-convert not found (brew install librsvg)", file=sys.stderr)
        return 1
    if shutil.which("sips") is None:
        print("error: sips not found (macOS-only tool)", file=sys.stderr)
        return 1

    ASSET_DIR.mkdir(parents=True, exist_ok=True)

    svg_text = build_svg()
    SVG_OUT.write_text(svg_text)
    print(f"wrote {SVG_OUT.relative_to(REPO)}")

    # Render canonical 1024×1024 PNG (lands directly at the @2x 512 slot).
    subprocess.run(
        ["rsvg-convert", "-w", "1024", "-h", "1024",
         "-o", str(PNG_1024), str(SVG_OUT)],
        check=True,
    )
    print(f"rendered {PNG_1024.relative_to(REPO)} (1024×1024)")

    # Downsize to every other slot via sips.
    for filename, px, _slot in SLOTS:
        out = ASSET_DIR / filename
        if out == PNG_1024:
            continue
        subprocess.run(
            ["sips", "-Z", str(px), "-s", "format", "png",
             str(PNG_1024), "--out", str(out)],
            check=True,
            capture_output=True,
        )
        print(f"  → {filename} ({px}×{px})")

    write_contents_json(ASSET_DIR / "Contents.json")
    print(f"wrote {(ASSET_DIR / 'Contents.json').relative_to(REPO)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
