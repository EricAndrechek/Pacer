# Identity colors — design

Status: **shipped.** How Pacer picks the color for a project or a model —
the donut wedges, legend swatches, and membership dots. Lives in
`PacerUI/CollectionColor.swift` (generation) and `PacerUI/PacerDonut.swift`
(the shared chart + legend that consume it).

## Goals, and the one we gave up

A project/model color should be:

1. **Stable** — survives a folder rename, a git-remote change, or a
   leaderboard reshuffle. The same project is the same color tomorrow.
2. **Pretty** — vivid and cohesive, not muddy; readable on light and dark.
3. **Consistent** — one color per identity, *everywhere*: 7d or 90d,
   filtered by a collection or not, donut or dot.
4. **Distinct** — no two wedges in a donut look alike.

You can't have all four. (3) and (4) are in direct tension: guaranteeing the
*visible* slices are distinct means the color must depend on what else is
visible, which breaks "same color everywhere." **We chose 1 + 2 + 3 and gave
up a hard guarantee on 4.** See the decision below — it was deliberate;
don't silently re-add de-collision.

## Stability — the recorded seed

Color is a pure function of a **frozen seed**, not the live path.
`ProjectMeta.colorSeed` is recorded once by `ScanCoordinator` when a project
is first seen: the **git origin URL** if the project has one, else its
canonical path. Hashing that (not the live path) is what makes the color
survive a rename or a remote change. The same re-attribution pass that moves
budgets on an alias merge moves `ProjectMeta` too, so a merged project keeps
its color. Models need no DB record — their names are already stable; the
seed is `pacerShortModel(name)`.

## Prettiness — the OKLCH "pretty ridge"

`pacerGeneratedColor(seed)` hashes the seed (FNV-1a + a murmur avalanche
finalizer, so sibling paths like `…/acme/api` and `…/acme/web` scatter
across the wheel instead of clustering) into a **continuous hue**, then
reads lightness + chroma from a **ridge** sampled from Apple's macOS system
colors (`pacerColorRidge`). Pretty colors don't live on a flat plane:
measured in OKLCH, the system palette's lightness ranges 0.53–0.87 and
chroma 0.11–0.24 across the wheel — reds/blues/purples are deep and
saturated, yellow is light, teals are soft. A flat lightness/chroma washes
out the deep hues and muddies the light ones (the "mustard/olive" bug). The
ridge interpolates L+C by hue (smoothstep, wraparound) so a continuous hue
looks as good as the discrete palette it was sampled from. A hue-safe
light/deep jitter adds variety without ever darkening the yellow band into
mud.

The curated `pacerColorPalette` survives only as the **collection color
picker grid** (a manual `colorHex` override); auto colors are generated.

## The decision: pure hash, not de-collision

We shipped, then reverted, a render-time **de-collision** pass that
guaranteed distinct slices (goal 4) by nudging any too-close pair apart. It
was reverted because it computed over the *visible* set, so a project's
color changed when the time range or collection filter changed the top-N —
breaking consistency (goal 3), which matters more.

The measured trade-off, over thousands of random project sets:

| how similar (OKLab ΔE) | 5-slice donut | 8-slice donut |
|---|---|---|
| < 0.06 (nearly identical) | ~40% | ~75% |
| < 0.10 (confusingly similar) | ~72% | ~98% |
| < 0.14 (clearly close) | ~91% | 100% |

So pure hash produces a look-alike pair in **~70% of five-slice donuts** —
it's not bad luck, the pretty-color space is just too small to scatter a
handful of random points without overlap. A second value dimension barely
helped (72%→72%). We accept this: consistency and dead-simple, portable,
predictable color beat guaranteed-distinct-but-shifting.

Alternatives considered and **rejected** — don't re-propose without new
information:

- **Render-path de-collision** (what we reverted): distinct per chart, but
  a project's color depends on the visible set → shifts across range/filter.
- **Persist a distinct color per project** (assign at first-seen, store it):
  consistent, but the color then depends on *what else existed when the
  project was first scanned* — a DB rebuild in a different scan order
  recolors projects, so it's no longer a pure function of identity. Also
  capacity-bounded (~9 distinct in 1-D, ~25–30 with a value axis); nothing
  keeps 50 projects distinct.

If distinctness ever becomes a hard requirement, the least-bad option is
de-collision over the **full, stable project set** (view-independent), which
keeps consistency — but it still can't beat the capacity wall, so it wasn't
worth the complexity for the current app.

## The shared donut

`PacerDonut` (chart: ring + color pinning + hover highlight + a11y) and
`PacerDonutLegendRow` (swatch + label + caller trailing) are the single home
for every "share" card — Top projects, Token share, the dashboard per-model
card, project detail, day detail. They used to be five copy-pasted blocks
that drifted (three legends silently lost their color swatch). Callers own
their hover state and legend trailing; the chart and the swatch live once.
