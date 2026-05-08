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

    Glass-morphism treatment, after Apple's Tahoe-era HIG:
      - Background: deep gradient + radial halo to imply a lit dome
      - Squircle inner-rim highlight at the top (specular curvature)
      - Single thick arc as the focal element, treated as a glass band:
          * faint full-arc track underneath
          * color sweep (green→orange) for the active portion
          * top specular gloss + bottom inner shadow for depth
      - Glowing position orb instead of a needle, so the focal point
        reads even at 16-32 px where ticks/needles disappear into noise
    """
    # Squircle bounds
    sq_x = inset
    sq_y = inset
    sq_w = canvas - 2 * inset
    sq_h = canvas - 2 * inset
    corner_radius = sq_w * 0.2237  # macOS continuous-corner approximation

    # Everything inside the squircle is anchored to the squircle so the
    # inset only controls how much transparent margin sits around the
    # artwork.
    cx = sq_x + sq_w / 2
    cy = sq_y + sq_h * 0.555
    arc_r = sq_w * 0.302
    arc_w = sq_w * 0.116
    orb_r = sq_w * 0.072

    # Gauge sweep (math degrees, y-flipped). 220° → -40° clockwise = 260° arc.
    start_deg = 220.0
    end_deg = -40.0
    active_fraction = 0.64
    total_deg = (start_deg - end_deg) % 360
    active_end_deg = start_deg - active_fraction * total_deg

    track_path = arc_clockwise(cx, cy, arc_r, start_deg, end_deg)
    active_path = arc_clockwise(cx, cy, arc_r, start_deg, active_end_deg)

    # Position orb sits where the arc terminates.
    orb_x, orb_y = deg_to_xy(cx, cy, arc_r, active_end_deg)

    # Bounds for vertical gradients along the arc (top of arc to bottom).
    arc_top_y = cy - arc_r - arc_w / 2
    arc_bot_y = cy + math.sin(math.radians(start_deg)) * -arc_r + arc_w / 2

    # Filter blur amounts scale with canvas so they look the same at any size.
    halo_blur = sq_w * 0.018
    orb_glow_blur = sq_w * 0.022
    arc_drop_blur = sq_w * 0.012

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg width="{canvas}" height="{canvas}" viewBox="0 0 {canvas} {canvas}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <!-- Squircle background: deep indigo → royal blue → bright cyan. -->
    <linearGradient id="bg" x1="{sq_x}" y1="{sq_y}" x2="{sq_x + sq_w}" y2="{sq_y + sq_h}" gradientUnits="userSpaceOnUse">
      <stop offset="0%"   stop-color="#3B1F8F"/>
      <stop offset="45%"  stop-color="#3457D7"/>
      <stop offset="100%" stop-color="#22C8F0"/>
    </linearGradient>

    <!-- Soft radial halo behind the arc — implies "lit from within". -->
    <radialGradient id="bgHalo" cx="50%" cy="55%" r="55%">
      <stop offset="0%"   stop-color="#FFFFFF" stop-opacity="0.22"/>
      <stop offset="60%"  stop-color="#FFFFFF" stop-opacity="0.06"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>

    <!-- Squircle top inner-rim highlight (the "wet glass" curvature). -->
    <linearGradient id="rimGloss" x1="0" y1="{sq_y}" x2="0" y2="{sq_y + sq_h * 0.5:.0f}" gradientUnits="userSpaceOnUse">
      <stop offset="0%"   stop-color="#FFFFFF" stop-opacity="0.34"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>

    <!-- Active arc color sweep. The gradient spans the full diameter of
         the gauge, but only the start..active portion of the arc is
         drawn — so we shift the stops left so meaningful warm color
         lands in the visible 0..62% region rather than hiding orange
         in the unrendered tail. -->
    <linearGradient id="arcSweep" x1="{cx - arc_r:.0f}" y1="{cy:.0f}" x2="{cx + arc_r:.0f}" y2="{cy:.0f}" gradientUnits="userSpaceOnUse">
      <stop offset="0%"   stop-color="#3BD66E"/>
      <stop offset="25%"  stop-color="#A8E04A"/>
      <stop offset="50%"  stop-color="#FFC93A"/>
      <stop offset="78%"  stop-color="#FF8C2E"/>
      <stop offset="100%" stop-color="#FF5A4A"/>
    </linearGradient>

    <!-- Glass top highlight (white@top, fading into the arc body). -->
    <linearGradient id="arcGloss" x1="0" y1="{arc_top_y:.0f}" x2="0" y2="{cy:.0f}" gradientUnits="userSpaceOnUse">
      <stop offset="0%"   stop-color="#FFFFFF" stop-opacity="0.65"/>
      <stop offset="55%"  stop-color="#FFFFFF" stop-opacity="0.10"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>

    <!-- Inner shadow on the lower curve of the arc (depth). -->
    <linearGradient id="arcShade" x1="0" y1="{cy:.0f}" x2="0" y2="{arc_bot_y:.0f}" gradientUnits="userSpaceOnUse">
      <stop offset="0%"   stop-color="#000000" stop-opacity="0"/>
      <stop offset="100%" stop-color="#000000" stop-opacity="0.22"/>
    </linearGradient>

    <!-- Position orb body: bright white core that fades into a soft blue hint. -->
    <radialGradient id="orbBody" cx="38%" cy="32%" r="70%">
      <stop offset="0%"   stop-color="#FFFFFF"/>
      <stop offset="55%"  stop-color="#FFFFFF"/>
      <stop offset="100%" stop-color="#CFE3FF"/>
    </radialGradient>

    <!-- Soft blur for the background halo. -->
    <filter id="haloBlur" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="{halo_blur:.2f}"/>
    </filter>

    <!-- Orb glow: blurred white halo behind the orb body. -->
    <filter id="orbGlow" x="-100%" y="-100%" width="300%" height="300%">
      <feGaussianBlur stdDeviation="{orb_glow_blur:.2f}"/>
    </filter>

    <!-- Drop shadow under the active arc — anchors it on the bg. -->
    <filter id="arcDropShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="{arc_drop_blur:.2f}"/>
      <feOffset dx="0" dy="{sq_w * 0.010:.2f}"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.42"/></feComponentTransfer>
      <feMerge>
        <feMergeNode/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>

    <!-- Clip the arc-gloss layer to the active arc stroke so the gloss
         doesn't bleed past the colored band. -->
    <clipPath id="arcClip">
      <path d="{active_path}" fill="none" stroke="#000" stroke-width="{arc_w:.2f}" stroke-linecap="round"/>
    </clipPath>
  </defs>

  <!-- 1. Squircle background -->
  <rect x="{sq_x}" y="{sq_y}" width="{sq_w}" height="{sq_h}" rx="{corner_radius:.2f}" ry="{corner_radius:.2f}" fill="url(#bg)"/>

  <!-- 2. Soft radial halo behind the arc -->
  <g clip-path="inset(0 round {corner_radius:.2f}px)">
    <rect x="{sq_x}" y="{sq_y}" width="{sq_w}" height="{sq_h}" fill="url(#bgHalo)" filter="url(#haloBlur)"/>
  </g>

  <!-- 3. Squircle top rim highlight -->
  <rect x="{sq_x}" y="{sq_y}" width="{sq_w}" height="{sq_h}" rx="{corner_radius:.2f}" ry="{corner_radius:.2f}" fill="url(#rimGloss)"/>

  <!-- 4. Faint full-arc track -->
  <path d="{track_path}" fill="none" stroke="#FFFFFF" stroke-opacity="0.14"
        stroke-width="{arc_w:.2f}" stroke-linecap="round"/>

  <!-- 5. Active arc — color sweep + drop shadow -->
  <g filter="url(#arcDropShadow)">
    <path d="{active_path}" fill="none" stroke="url(#arcSweep)"
          stroke-width="{arc_w:.2f}" stroke-linecap="round"/>
  </g>

  <!-- 6. Glass top gloss + bottom inner shade, clipped to the active arc -->
  <g clip-path="url(#arcClip)">
    <rect x="{sq_x}" y="{sq_y}" width="{sq_w}" height="{sq_h}" fill="url(#arcGloss)"/>
    <rect x="{sq_x}" y="{sq_y}" width="{sq_w}" height="{sq_h}" fill="url(#arcShade)"/>
  </g>

  <!-- 7. Position orb: glow halo + body + specular highlight -->
  <circle cx="{orb_x:.2f}" cy="{orb_y:.2f}" r="{orb_r * 1.35:.2f}"
          fill="#FFFFFF" fill-opacity="0.32" filter="url(#orbGlow)"/>
  <circle cx="{orb_x:.2f}" cy="{orb_y:.2f}" r="{orb_r:.2f}" fill="url(#orbBody)"/>
  <ellipse cx="{orb_x - orb_r * 0.32:.2f}" cy="{orb_y - orb_r * 0.42:.2f}"
           rx="{orb_r * 0.42:.2f}" ry="{orb_r * 0.26:.2f}"
           fill="#FFFFFF" fill-opacity="0.85"/>
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
