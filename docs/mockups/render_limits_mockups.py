#!/usr/bin/env python3
"""Standalone mockups for Pacer's adaptive `limits[]` card.

Ports the REAL color math from PacerCore so the design iterates on true
colors:
  - UsageBand(percentage): <50 green, <75 yellow, <90 orange, else red
    (PacerCore/RateLimit/UsageBand.swift)
  - severity floor blend: severity can only escalate the band, never mask a
    hot percent; unknown severity => green floor (UsageLimits.swift)

Renders two directions (A: grouped ledger, B: meter-tile grid), each in
dark + light, so Eric can pick a direction before we polish the in-app card.
"""
from PIL import Image, ImageDraw, ImageFont

SCALE = 2  # supersample for crisp text, downsample at save

# ---- Ported color math -----------------------------------------------------

def usage_band(pct):
    if pct < 50:  return "green"
    if pct < 75:  return "yellow"
    if pct < 90:  return "orange"
    return "red"

_SEV_FLOOR = {  # subset of UsageLimitSeverity.floor
    "warning": "orange", "warn": "orange", "elevated": "orange",
    "approaching": "orange", "near_limit": "orange",
    "critical": "red", "exceeded": "red", "blocked": "red",
    "hard": "red", "over_limit": "red", "throttled": "red",
}
_RANK = {"green": 0, "yellow": 1, "orange": 2, "red": 3}

def display_band(pct, severity):
    floor = _SEV_FLOOR.get(severity.lower(), "green")
    by_pct = usage_band(pct)
    return by_pct if _RANK[by_pct] >= _RANK[floor] else floor

# ---- Palettes (approx macOS system colors) --------------------------------

BAND_DARK = {"green": (48, 209, 88), "yellow": (255, 214, 10),
             "orange": (255, 159, 10), "red": (255, 69, 58)}
BAND_LIGHT = {"green": (40, 205, 65), "yellow": (255, 204, 0),
              "orange": (255, 149, 0), "red": (255, 59, 48)}

THEME = {
    "dark": dict(page=(22, 22, 24), card=(38, 38, 41), stroke=(255, 255, 255, 18),
                 primary=(255, 255, 255), secondary=(152, 152, 157),
                 tertiary=(108, 108, 116), track=(255, 255, 255, 28),
                 accent=(10, 132, 255), bind_tint=(10, 132, 255, 34),
                 chip_bg=(10, 132, 255, 46), band=BAND_DARK, tile=(46, 46, 50)),
    "light": dict(page=(238, 238, 240), card=(255, 255, 255), stroke=(0, 0, 0, 16),
                  primary=(0, 0, 0), secondary=(110, 110, 115),
                  tertiary=(150, 150, 156), track=(0, 0, 0, 22),
                  accent=(0, 122, 255), bind_tint=(0, 122, 255, 28),
                  chip_bg=(0, 122, 255, 40), band=BAND_LIGHT, tile=(247, 247, 249)),
}

def font(name, size):
    return ImageFont.truetype(f"/System/Library/Fonts/{name}", size * SCALE)

F = lambda s: font("SFNS.ttf", s)
FR = lambda s: font("SFNSRounded.ttf", s)  # rounded, matches app numerals/titles

# ---- Sample data (adaptive: mixed models/kinds/groups/severities) ----------
# Demonstrates every band + the binding highlight + a per-model scoped row.
GROUPS = [
    ("Session", [
        dict(label="All models", pct=39, sev="normal", active=True, reset="resets in 2h · 4:19 PM"),
    ]),
    ("Weekly", [
        dict(label="All models", pct=71, sev="normal", active=True, reset="resets Mon · 10 AM", binding=True),
        dict(label="Haiku",      pct=93, sev="normal", active=False, reset="resets Mon · 10 AM"),
        dict(label="Opus",       pct=84, sev="normal", active=False, reset="resets Mon · 10 AM"),
        dict(label="Fable",      pct=49, sev="normal", active=False, reset="resets Mon · 10 AM"),
        dict(label="Sonnet",     pct=22, sev="normal", active=False, reset="resets Mon · 10 AM"),
    ]),
]

def blend(fg, bg, a):
    """Manual alpha blend -> solid RGB (ImageDraw fills don't composite)."""
    return tuple(round(fg[i] * a + bg[i] * (1 - a)) for i in range(3))

def rr(d, box, r, **kw):
    d.rounded_rectangle(box, radius=r * SCALE, **kw)

def text(d, xy, s, fnt, fill, anchor="la"):
    d.text((xy[0] * SCALE, xy[1] * SCALE), s, font=fnt, fill=fill, anchor=anchor)

def measure(d, s, fnt):
    b = d.textbbox((0, 0), s, font=fnt)
    return (b[2] - b[0]) / SCALE, (b[3] - b[1]) / SCALE

# ---- Direction A: grouped ledger (horizontal bars) -------------------------

def render_A(theme):
    t = THEME[theme]
    W, H = 720, 500
    img = Image.new("RGBA", (W * SCALE, H * SCALE), t["page"])
    d = ImageDraw.Draw(img, "RGBA")

    # Card
    pad = 20
    cx0, cy0, cx1, cy1 = 24, 24, W - 24, H - 24
    rr(d, [cx0 * SCALE, cy0 * SCALE, cx1 * SCALE, cy1 * SCALE], 14, fill=t["card"])
    rr(d, [cx0 * SCALE, cy0 * SCALE, cx1 * SCALE, cy1 * SCALE], 14, outline=t["stroke"], width=SCALE)

    x = cx0 + pad
    y = cy0 + pad
    text(d, (x, y), "Rate limits", FR(17), t["primary"])
    # trailing binding summary
    text(d, (cx1 - pad, y + 2), "weekly · all models is binding", F(11), t["secondary"], anchor="ra")
    y += 34

    for gi, (group, rows) in enumerate(GROUPS):
        text(d, (x, y), group.upper(), F(10), t["secondary"])
        y += 20
        for r in rows:
            band = display_band(r["pct"], r["sev"])
            col = t["band"][band]
            binding = r.get("binding", False)
            row_h = 50
            bind_bg = blend(t["accent"], t["card"], 0.16)
            chip_bg = blend(t["accent"], t["card"], 0.24)
            if binding:
                rr(d, [(x - 10) * SCALE, (y - 7) * SCALE, (cx1 - pad + 10) * SCALE, (y + row_h - 9) * SCALE],
                   8, fill=bind_bg)
            # active dot
            if r["active"]:
                dot = 7
                d.ellipse([x * SCALE, (y + 3) * SCALE, (x + dot) * SCALE, (y + 3 + dot) * SCALE], fill=col)
                lx = x + 14
            else:
                lx = x
            text(d, (lx, y), r["label"], F(13.5), t["primary"])
            if binding:
                cw, _ = measure(d, "binding", F(10))
                chip_x = lx + measure(d, r["label"], F(13.5))[0] + 10
                rr(d, [chip_x * SCALE, (y + 1) * SCALE, (chip_x + cw + 14) * SCALE, (y + 16) * SCALE],
                   7, fill=chip_bg)
                text(d, (chip_x + 7, y + 2), "binding", F(10), t["accent"])
            # percent right-aligned
            text(d, (cx1 - pad, y - 1), f"{r['pct']}%", FR(14), col, anchor="ra")
            # bar
            by = y + 21
            bx1 = cx1 - pad
            track = blend((255, 255, 255) if theme == "dark" else (0, 0, 0), t["card"], 0.10)
            rr(d, [x * SCALE, by * SCALE, bx1 * SCALE, (by + 6) * SCALE], 3, fill=track)
            fillw = (bx1 - x) * (r["pct"] / 100.0)
            rr(d, [x * SCALE, by * SCALE, (x + fillw) * SCALE, (by + 6) * SCALE], 3, fill=col)
            # reset caption
            text(d, (x, by + 11), r["reset"], F(10.5), t["tertiary"])
            y += row_h
        y += 10

    return img.resize((W, H), Image.LANCZOS)

# ---- Direction B: meter-tile grid ------------------------------------------

def render_B(theme):
    t = THEME[theme]
    W, H = 720, 386
    img = Image.new("RGBA", (W * SCALE, H * SCALE), t["page"])
    d = ImageDraw.Draw(img, "RGBA")

    pad = 20
    cx0, cy0, cx1, cy1 = 24, 24, W - 24, H - 24
    rr(d, [cx0 * SCALE, cy0 * SCALE, cx1 * SCALE, cy1 * SCALE], 14, fill=t["card"])
    rr(d, [cx0 * SCALE, cy0 * SCALE, cx1 * SCALE, cy1 * SCALE], 14, outline=t["stroke"], width=SCALE)

    x = cx0 + pad
    y = cy0 + pad
    text(d, (x, y), "Rate limits", FR(17), t["primary"])
    text(d, (cx1 - pad, y + 2), "grouped by window · binding highlighted", F(11), t["secondary"], anchor="ra")
    y += 36

    # flatten to tiles, keep group as eyebrow on each tile
    tiles = []
    for group, rows in GROUPS:
        for r in rows:
            tiles.append((group, r))

    cols = 3
    gap = 12
    tile_w = (cx1 - pad - (x)) / cols - gap * (cols - 1) / cols
    tile_h = 96
    for i, (group, r) in enumerate(tiles):
        c = i % cols
        row = i // cols
        tx = x + c * (tile_w + gap)
        ty = y + row * (tile_h + gap)
        band = display_band(r["pct"], r["sev"])
        col = t["band"][band]
        binding = r.get("binding", False)
        rr(d, [tx * SCALE, ty * SCALE, (tx + tile_w) * SCALE, (ty + tile_h) * SCALE], 10, fill=t["tile"])
        if binding:
            rr(d, [tx * SCALE, ty * SCALE, (tx + tile_w) * SCALE, (ty + tile_h) * SCALE],
               10, outline=t["accent"], width=2 * SCALE)
        # left accent bar
        rr(d, [tx * SCALE, (ty + 12) * SCALE, (tx + 4) * SCALE, (ty + tile_h - 12) * SCALE], 2, fill=col)
        ix = tx + 14
        text(d, (ix, ty + 12), group.upper(), F(9), t["secondary"])
        text(d, (ix, ty + 24), r["label"], F(13), t["primary"])
        text(d, (ix, ty + 44), f"{r['pct']}%", FR(26), col)
        if binding:
            text(d, (tx + tile_w - 12, ty + 12), "BINDING", F(9), t["accent"], anchor="ra")
        # mini bar at bottom
        by = ty + tile_h - 16
        bx1 = tx + tile_w - 12
        rr(d, [ix * SCALE, by * SCALE, bx1 * SCALE, (by + 5) * SCALE], 2, fill=t["track"])
        fw = (bx1 - ix) * (r["pct"] / 100.0)
        rr(d, [ix * SCALE, by * SCALE, (ix + fw) * SCALE, (by + 5) * SCALE], 2, fill=col)

    return img.resize((W, H), Image.LANCZOS)

# ---- Emit ------------------------------------------------------------------

if __name__ == "__main__":
    import os
    out = os.path.dirname(os.path.abspath(__file__))
    render_A("dark").save(f"{out}/limits-A-grouped-dark.png")
    render_A("light").save(f"{out}/limits-A-grouped-light.png")
    render_B("dark").save(f"{out}/limits-B-tiles-dark.png")
    print("wrote limits-A-grouped-{dark,light}.png, limits-B-tiles-dark.png")
