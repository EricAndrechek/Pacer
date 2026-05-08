#!/usr/bin/env python3
"""
Generate Pacer's app icon and brand logo.

Two outputs from one design:

1. App/Assets.xcassets/AppIcon.appiconset/ — sized for macOS's app icon
   slot. Apple's design grid puts the squircle artwork inside an
   ≈824×824 area centered in a 1024×1024 transparent canvas (≈100px
   margin on all sides). Without that margin, third-party icons render
   noticeably bigger than native apps in the Dock.

2. App/Assets.xcassets/PacerLogo.imageset/ — same artwork, but
   edge-to-edge (no margin). For in-app use (sidebar brand block, menu
   bar popover header, About card, welcome card) where transparent
   padding would make the logo look smaller than surrounding text.

Re-run any time the design changes:
    python3 bin/generate-icon.py
"""

from __future__ import annotations

import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "App" / "Assets.xcassets"
APPICON_DIR = ASSETS / "AppIcon.appiconset"
LOGO_DIR = ASSETS / "PacerLogo.imageset"

# Authoring source SVGs (committed alongside the script for diff-ability).
SVG_APPICON = REPO / "bin" / "icon.svg"          # full 1024 with margin
SVG_LOGO = REPO / "bin" / "icon-logo.svg"        # 1024 edge-to-edge


def deg_to_xy(cx: float, cy: float, r: float, deg: float) -> tuple[float, float]:
    """Math degrees (0=right, 90=up) → SVG screen coords (y-flipped)."""
    rad = math.radians(deg)
    return (cx + r * math.cos(rad), cy - r * math.sin(rad))


def arc_clockwise(cx: float, cy: float, r: float,
                  start_deg: float, end_deg: float) -> str:
    """SVG path string for a visually-clockwise arc."""
    delta = (start_deg - end_deg) % 360 or 360
    large_arc = 1 if delta > 180 else 0
    sweep = 1
    sx, sy = deg_to_xy(cx, cy, r, start_deg)
    ex, ey = deg_to_xy(cx, cy, r, end_deg)
    return f"M {sx:.2f} {sy:.2f} A {r:.2f} {r:.2f} 0 {large_arc} {sweep} {ex:.2f} {ey:.2f}"


def build_svg(canvas: int, inset: int) -> str:
    """
    Render the full 1024×1024 canvas. The squircle is drawn from `inset`
    to `canvas - inset` on each side. With inset=100, this produces the
    Apple-grid AppIcon. With inset=0, the squircle goes edge-to-edge
    for the in-app PacerLogo.
    """
    # Squircle bounds
    sq_x = inset
    sq_y = inset
    sq_w = canvas - 2 * inset
    sq_h = canvas - 2 * inset
    corner_radius = sq_w * 0.2237  # macOS continuous-corner approximation

    # Geometry for everything that lives inside the squircle is anchored
    # to the squircle, not the canvas, so the inset only controls how
    # much transparent margin sits around the artwork.
    cx = sq_x + sq_w / 2
    cy = sq_y + sq_h * 0.575
    gauge_r = sq_w * 0.314
    gauge_thickness = sq_w * 0.088
    needle_len = gauge_r - sq_w * 0.018
    needle_base = sq_w * 0.029
    cap_r = sq_w * 0.037
    cap_inner_r = sq_w * 0.0137
    tick_len_inner = gauge_r + gauge_thickness / 2 + sq_w * 0.0215
    tick_len_outer = gauge_r + gauge_thickness / 2 + sq_w * 0.0547
    tick_stroke = sq_w * 0.0107

    # Gauge sweep (math degrees, y-flipped). 220° → -40° clockwise = 260° arc.
    start_deg = 220.0
    end_deg = -40.0
    active_fraction = 0.62
    total_deg = (start_deg - end_deg) % 360
    active_end_deg = start_deg - active_fraction * total_deg

    track_path = arc_clockwise(cx, cy, gauge_r, start_deg, end_deg)
    active_path = arc_clockwise(cx, cy, gauge_r, start_deg, active_end_deg)

    # Needle as a tapered triangle.
    tip = deg_to_xy(cx, cy, needle_len, active_end_deg)
    perp = math.radians(active_end_deg) + math.pi / 2
    bdx = needle_base * math.cos(perp)
    bdy = -needle_base * math.sin(perp)
    base_l = (cx + bdx, cy + bdy)
    base_r = (cx - bdx, cy - bdy)

    # Tick marks at 5 evenly-spaced positions.
    ticks: list[str] = []
    n_ticks = 5
    for i in range(n_ticks):
        frac = i / (n_ticks - 1)
        deg = start_deg - frac * total_deg
        ix, iy = deg_to_xy(cx, cy, tick_len_inner, deg)
        ox, oy = deg_to_xy(cx, cy, tick_len_outer, deg)
        ticks.append(
            f'<line x1="{ix:.1f}" y1="{iy:.1f}" x2="{ox:.1f}" y2="{oy:.1f}" '
            f'stroke="#FFFFFF" stroke-opacity="0.55" stroke-width="{tick_stroke:.2f}" stroke-linecap="round"/>'
        )

    # Background gradient anchored to the squircle (not the canvas), so
    # the gradient direction looks the same regardless of inset.
    gloss_h = sq_h * 0.55
    needle_blur = sq_w * 0.0107

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg width="{canvas}" height="{canvas}" viewBox="0 0 {canvas} {canvas}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="{sq_x}" y1="{sq_y}" x2="{sq_x + sq_w}" y2="{sq_y + sq_h}" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#6E45E2"/>
      <stop offset="55%" stop-color="#3B82F6"/>
      <stop offset="100%" stop-color="#00C6FB"/>
    </linearGradient>
    <linearGradient id="topGloss" x1="{sq_x}" y1="{sq_y}" x2="{sq_x}" y2="{sq_y + gloss_h:.0f}" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.22"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="gaugeSweep" x1="{cx - gauge_r:.0f}" y1="{cy:.0f}" x2="{cx + gauge_r:.0f}" y2="{cy:.0f}" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#34D158"/>
      <stop offset="55%" stop-color="#FFCC00"/>
      <stop offset="100%" stop-color="#FF9500"/>
    </linearGradient>
    <radialGradient id="centerCap" cx="50%" cy="40%" r="60%">
      <stop offset="0%" stop-color="#FFFFFF"/>
      <stop offset="100%" stop-color="#E0E8FF"/>
    </radialGradient>
    <filter id="needleShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="{needle_blur:.2f}"/>
      <feOffset dx="0" dy="{sq_w * 0.006:.2f}"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.45"/></feComponentTransfer>
      <feMerge>
        <feMergeNode/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
  </defs>

  <!-- Squircle background + glossy top highlight -->
  <rect x="{sq_x}" y="{sq_y}" width="{sq_w}" height="{sq_h}" rx="{corner_radius:.2f}" ry="{corner_radius:.2f}" fill="url(#bg)"/>
  <rect x="{sq_x}" y="{sq_y}" width="{sq_w}" height="{sq_h}" rx="{corner_radius:.2f}" ry="{corner_radius:.2f}" fill="url(#topGloss)"/>

  <!-- Tick marks -->
  {chr(10).join("  " + t for t in ticks)}

  <!-- Gauge track -->
  <path d="{track_path}" fill="none" stroke="#FFFFFF" stroke-opacity="0.20"
        stroke-width="{gauge_thickness:.2f}" stroke-linecap="round"/>

  <!-- Active sweep -->
  <path d="{active_path}" fill="none" stroke="url(#gaugeSweep)"
        stroke-width="{gauge_thickness:.2f}" stroke-linecap="round"/>

  <!-- Needle -->
  <g filter="url(#needleShadow)">
    <polygon points="{base_l[0]:.2f},{base_l[1]:.2f} {tip[0]:.2f},{tip[1]:.2f} {base_r[0]:.2f},{base_r[1]:.2f}"
             fill="#FFFFFF"/>
  </g>

  <!-- Center cap -->
  <circle cx="{cx:.2f}" cy="{cy:.2f}" r="{cap_r:.2f}" fill="url(#centerCap)"/>
  <circle cx="{cx:.2f}" cy="{cy:.2f}" r="{cap_inner_r:.2f}" fill="#3B82F6"/>
</svg>
"""


# ----- macOS app icon slots -----

APPICON_SLOTS: list[tuple[str, int, str]] = [
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


def write_appicon_contents(path: Path) -> None:
    images = []
    for filename, _px, slot in APPICON_SLOTS:
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


# PacerLogo gets the standard macOS imageset shape: universal idiom,
# 1x and 2x. SwiftUI scales these down with .resizable() to whatever
# size the call site needs (sidebar 22pt, About 44pt, etc.).
LOGO_SLOTS: list[tuple[str, int, str]] = [
    ("PacerLogo.png",     256,  "1x"),
    ("PacerLogo@2x.png",  512,  "2x"),
]


def write_logo_contents(path: Path) -> None:
    images = [
        {"filename": filename, "idiom": "universal", "scale": scale}
        for filename, _px, scale in LOGO_SLOTS
    ]
    payload = {
        "images": images,
        "info": {"author": "xcode", "version": 1},
    }
    path.write_text(json.dumps(payload, indent=2) + "\n")


def render(svg_path: Path, out_png: Path) -> None:
    subprocess.run(
        ["rsvg-convert", "-w", "1024", "-h", "1024",
         "-o", str(out_png), str(svg_path)],
        check=True,
    )


def downsize(src_1024: Path, dst: Path, px: int) -> None:
    if px == 1024 and dst != src_1024:
        shutil.copyfile(src_1024, dst)
        return
    subprocess.run(
        ["sips", "-Z", str(px), "-s", "format", "png",
         str(src_1024), "--out", str(dst)],
        check=True,
        capture_output=True,
    )


def main() -> int:
    if shutil.which("rsvg-convert") is None:
        print("error: rsvg-convert not found (brew install librsvg)", file=sys.stderr)
        return 1
    if shutil.which("sips") is None:
        print("error: sips not found (macOS-only tool)", file=sys.stderr)
        return 1

    APPICON_DIR.mkdir(parents=True, exist_ok=True)
    LOGO_DIR.mkdir(parents=True, exist_ok=True)

    # === AppIcon: artwork in 824×824 inside a 1024×1024 transparent canvas. ===
    SVG_APPICON.write_text(build_svg(canvas=1024, inset=100))
    print(f"wrote {SVG_APPICON.relative_to(REPO)}")

    appicon_1024 = APPICON_DIR / "icon_512x512@2x.png"
    render(SVG_APPICON, appicon_1024)
    print(f"rendered {appicon_1024.relative_to(REPO)} (1024×1024 with margin)")

    for filename, px, _slot in APPICON_SLOTS:
        out = APPICON_DIR / filename
        if out == appicon_1024:
            continue
        downsize(appicon_1024, out, px)
        print(f"  → {filename} ({px}×{px})")

    write_appicon_contents(APPICON_DIR / "Contents.json")
    print(f"wrote {(APPICON_DIR / 'Contents.json').relative_to(REPO)}")

    # === PacerLogo: artwork edge-to-edge for in-app use. ===
    SVG_LOGO.write_text(build_svg(canvas=1024, inset=0))
    print(f"wrote {SVG_LOGO.relative_to(REPO)}")

    logo_1024 = LOGO_DIR / "_master.png"
    render(SVG_LOGO, logo_1024)
    for filename, px, _scale in LOGO_SLOTS:
        out = LOGO_DIR / filename
        downsize(logo_1024, out, px)
        print(f"  → {filename} ({px}×{px})")
    logo_1024.unlink()

    write_logo_contents(LOGO_DIR / "Contents.json")
    print(f"wrote {(LOGO_DIR / 'Contents.json').relative_to(REPO)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
