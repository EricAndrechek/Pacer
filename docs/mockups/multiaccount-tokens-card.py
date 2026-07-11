#!/usr/bin/env python3
"""Standalone PIL mockup of the multi-account Tokens settings card.
Design-iteration only — ports Pacer's dark card look approximately so we can
sign off the account switcher + grouped token list BEFORE building in-app."""
from PIL import Image, ImageDraw, ImageFont
import os

SCALE = 2  # render @2x for crispness
W, H = 720, 548

# palette (approx Pacer dark)
BG        = (28, 28, 30)
CARD      = (36, 36, 38)
CARD_EDGE = (255, 255, 255, 20)
TXT       = (235, 235, 240)
SEC       = (165, 165, 172)
TER       = (120, 120, 128)
GREEN     = (76, 200, 120)
ORANGE    = (235, 165, 70)
PURPLE    = (180, 140, 235)
ACCENT    = (90, 150, 245)
HILITE    = (90, 150, 245, 38)
CHIPBG    = (255, 255, 255, 16)

def blend(c, a, base=CARD):
    """Solid RGB of color c at opacity a over base (Pillow flattens fill
    alpha to opaque, so pre-blend tints ourselves)."""
    return tuple(int(base[i] * (1 - a) + c[i] * a) for i in range(3))

def font(sz, bold=False):
    paths = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]
    for p in paths:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, sz * SCALE)
            except Exception:
                pass
    return ImageFont.load_default()

def rr(d, xy, r, fill=None, outline=None, width=1):
    d.rounded_rectangle([c * SCALE for c in xy], radius=r * SCALE, fill=fill,
                        outline=outline, width=width * SCALE)

def text(d, xy, s, f, fill=TXT, anchor="la"):
    d.text((xy[0] * SCALE, xy[1] * SCALE), s, font=f, fill=fill, anchor=anchor)

def minibar(d, x, y, w, pct, color):
    h = 5
    rr(d, (x, y, x + w, y + h), 2, fill=blend((255, 255, 255), 0.10))
    fw = max(3, int(w * pct / 100))
    rr(d, (x, y, x + fw, y + h), 2, fill=color)

def hline(d, x0, x1, y, a=0.09):
    d.line([x0 * SCALE, y * SCALE, x1 * SCALE, y * SCALE], fill=blend((255, 255, 255), a), width=1)

def pct_color(p):
    return GREEN if p < 50 else (ORANGE if p < 85 else (230, 90, 90))

img = Image.new("RGBA", (W * SCALE, H * SCALE), BG)
d = ImageDraw.Draw(img, "RGBA")

f_title = font(15, True)
f_body  = font(12)
f_bold  = font(12, True)
f_small = font(10)
f_tiny  = font(8, True)
f_cap   = font(11)

# ---------------- Card ----------------
cx, cy, cw = 24, 20, W - 48
card_h = H - 40
rr(d, (cx, cy, cx + cw, cy + card_h), 12, fill=CARD, outline=CARD_EDGE, width=1)

px = cx + 20            # content left pad
pr = cx + cw - 20       # content right edge
y = cy + 18

# header
text(d, (px, y), "Tokens", f_title)
# cadence pill (right)
cad = "Updating ~1 min · 2 tokens · active"
tw = d.textlength(cad, font=f_cap) / SCALE
d.ellipse([((pr - tw - 16) * SCALE), (y + 3) * SCALE, ((pr - tw - 16) + 7) * SCALE, (y + 10) * SCALE], fill=GREEN)
text(d, (pr, y), cad, f_cap, fill=SEC, anchor="ra")
y += 34

# ---------------- ACCOUNTS switcher ----------------
text(d, (px, y), "ACCOUNTS", f_tiny, fill=TER)
y += 18

def account_row(y, name, plan, org, five, seven, active):
    rowh = 54
    if active:
        rr(d, (px - 8, y, pr + 8, y + rowh), 9, fill=blend(ACCENT, 0.14),
           outline=blend(ACCENT, 0.55), width=1)
    # left: name + plan + org
    text(d, (px + 4, y + 9), name, f_bold)
    nw = d.textlength(name, font=f_bold) / SCALE
    text(d, (px + 4 + nw + 8, y + 10), plan, f_small, fill=SEC)
    text(d, (px + 4, y + 30), org, f_small, fill=TER)
    # right: usage readouts + action
    if active:
        # Active pill
        pw = 52
        rr(d, (pr - pw - 4, y + 9, pr - 4, y + 27), 9, fill=blend(GREEN, 0.22, base=blend(ACCENT, 0.14)))
        text(d, (pr - pw / 2 - 4, y + 12), "Active", f_small, fill=GREEN, anchor="ma")
    else:
        pw = 62
        rr(d, (pr - pw - 4, y + 9, pr - 4, y + 29), 6, fill=blend((255,255,255), 0.08),
           outline=blend((255,255,255), 0.22), width=1)
        text(d, (pr - pw / 2 - 4, y + 13), "Switch", f_small, fill=TXT, anchor="ma")
    # mini usage
    ux = pr - 210
    text(d, (ux, y + 30), "5h", f_small, fill=TER)
    minibar(d, ux + 22, y + 33, 60, five, pct_color(five))
    text(d, (ux + 88, y + 30), f"{five}%", f_small, fill=SEC)
    text(d, (ux + 120, y + 30), "7d", f_small, fill=TER)
    minibar(d, ux + 142, y + 33, 60, seven, pct_color(seven))
    text(d, (ux + 208, y + 30), f"{seven}%", f_small, fill=SEC, anchor="ra")
    return y + rowh + 6

y = account_row(y, "Work", "max20x", "org · …a1f9 · 2 tokens", 62, 41, True)
y = account_row(y, "Personal", "max5x", "org · …7b2c · 1 token", 12, 5, False)
y += 6

# divider
hline(d, px - 8, pr + 8, y, a=0.12)
y += 14

# ---------------- token table (grouped by account) ----------------
# column header
colx = {"src": px, "acct": px + 250, "status": pr - 210, "exp": pr - 130, "upd": pr - 66}
text(d, (colx["src"], y), "SOURCE", f_tiny, fill=TER)
text(d, (colx["acct"], y), "ACCOUNT", f_tiny, fill=TER)
text(d, (colx["status"], y), "STATUS", f_tiny, fill=TER)
text(d, (colx["exp"], y), "EXPIRES", f_tiny, fill=TER)
text(d, (colx["upd"], y), "UPDATED", f_tiny, fill=TER)
y += 20

def status_pill(x, y, label, color):
    tw = d.textlength(label, font=f_small) / SCALE
    rr(d, (x, y, x + tw + 12, y + 17), 8, fill=blend(color, 0.20))
    text(d, (x + 6, y + 2), label, f_small, fill=color)

def group_label(y, s):
    text(d, (px, y), s, f_tiny, fill=blend(ACCENT, 0.85))
    return y + 16

def lane(y, icon_txt, name, fp, acct, status, scolor, exp, upd, dim=False):
    hline(d, px - 8, pr + 8, y, a=0.07)
    y += 8
    nc = SEC if dim else TXT
    text(d, (colx["src"], y + 2), icon_txt, f_body, fill=SEC)
    text(d, (colx["src"] + 22, y), name, f_bold, fill=nc)
    text(d, (colx["src"] + 22, y + 16), f"#{fp}", f_small, fill=TER)
    text(d, (colx["acct"], y + 6), acct, f_small, fill=SEC)
    status_pill(colx["status"], y + 4, status, scolor)
    text(d, (colx["exp"], y + 6), exp, f_small, fill=SEC)
    text(d, (colx["upd"], y + 6), upd, f_small, fill=SEC)
    return y + 30

y = group_label(y, "WORK  ·  ACTIVE")
y = lane(y, "»_", "Claude Code", "a1b2c3", "org…a1f9", "active", GREEN, "12d", "2m ago")
y = lane(y, "▤",  "Claude Desktop", "d4e5f6", "org…a1f9", "active", GREEN, "8d", "4m ago")
y += 8
y = group_label(y, "PERSONAL")
y = lane(y, "⚿",  "Manual", "9f8e7d", "org…7b2c", "tracked", PURPLE, "—", "6m ago", dim=True)
y += 12

# footer
hline(d, px - 8, pr + 8, y, a=0.07)
y += 12
foot = ["Pacer tracks every account you're signed into. The active account drives the",
        "menu bar, dashboard, and alerts; other accounts are polled quietly and shown here.",
        "Switch anytime — each account keeps its own usage history."]
for line_txt in foot:
    text(d, (px, y), line_txt, f_small, fill=TER)
    y += 15

out_dir = os.path.join(os.path.dirname(__file__), "out")
os.makedirs(out_dir, exist_ok=True)
p = os.path.join(out_dir, "multiaccount-tokens-card.png")
img.convert("RGB").save(p)
print("wrote", p, img.size)
