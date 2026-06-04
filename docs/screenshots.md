# Screenshots

The README images in `docs/screenshots/` are **generated, not hand-captured** —
one command renders the real app views against synthetic data and writes
deterministic PNGs. This keeps them in sync with the UI and makes them a
first-class, repeatable part of the dev/release cycle.

```sh
make screenshots
```

## What it produces

| File | Scene | Notes |
| --- | --- | --- |
| `dashboard.png` / `dashboard-dark.png` | Main dashboard (`ContentView`) | macOS window chrome (traffic-light titlebar); light + dark |
| `history.png` | History view (`HistoryView`) | lifetime totals, six-month heatmap, monthly spend |
| `menubar.png` / `menubar-dark.png` | Menu-bar experience (`MenuBarExperience`) | the menu-bar readout chips + the click-down popover beneath, in one image; light + dark |
| `widgets.png` | Widget gallery | one composite of the real widget views (Today, pace gauges, live session, daily cost, top projects) |

All are rendered at 2× (Retina) with transparent margins, rounded corners, and a
soft drop shadow so they drop into the README — and a future App Store / press
kit — cleanly.

**Light/dark in the README.** The dashboard and menu-bar images ship in both
appearances, and the README uses `<picture>` with a
`(prefers-color-scheme: dark)` source so GitHub serves the matching one based on
the viewer's theme — no JS, just the standard element:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dashboard-dark.png">
  <img src="docs/screenshots/dashboard.png" alt="…">
</picture>
```

## How it works

Everything lives in [`App/Background/ScreenshotMode.swift`](../App/Background/ScreenshotMode.swift),
activated by the `PACER_SCREENSHOT_MODE=1` environment variable (the `make
screenshots` target sets it and points `PACER_SCREENSHOT_DIR` at
`docs/screenshots/`).

When that flag is set, `PacerAppDelegate` takes a separate path:

1. **In-memory, synthetic data.** It swaps the on-disk App Group container for
   `PacerStore.makeInMemoryContainer()` and skips the single-instance gate, the
   stderr redirect, the menu-bar item, and the background scan/OAuth service. It
   **never reads or mutates the user's real `~/.claude` data or `pacer.sqlite`**,
   and is safe to run alongside a live Pacer.
2. **Seed.** `ScreenshotMode.seed(into:)` fills the container with deterministic
   data — six months of daily rollups, today's hourly breakdown, sessions, recent
   tokens, and rate-limit trails (see below). The *shapes* are calibrated from
   real heavy-user trends (Opus-dominant model mix, weekday-peaked spend with
   weekend dips and the odd spike day, cache reads ≈ 200–300× input+output with
   output ≫ non-cached input, and the rate-limit curves below). Absolute
   magnitudes are kept to a believable-heavy range for a public README rather
   than mirroring any one person's exact spend.
3. **Capture.** `ScreenshotMode.captureAll(...)` hosts each **real** view in an
   off-screen, never-activated window so the full SwiftUI lifecycle runs
   (`@Query` fetches land, `@State` caches refresh, Charts lay out — a one-shot
   `ImageRenderer` pass renders empty cards, which is why we use a real window),
   then snapshots the hosting view to a PNG.
4. **Exit.** The process exits when done.

Because the window is positioned far off-screen and the app never activates,
running this **steals no focus** — you can keep working while it renders.

### Gotchas worth knowing (and not re-discovering)

- **Opaque backing is load-bearing.** A SwiftUI `ScrollView`'s background is
  *clear*. In dark mode the page-title text is *white*, so without an opaque
  backing it flattens onto the transparent capture and survives only as its grey
  anti-alias fringe — a "ghost" header. The `card: true` capture path renders the
  content over `Color(nsColor: .windowBackgroundColor)` to prevent this (and it
  improves card separation in light mode too).
- **Lifecycle, not `ImageRenderer`.** The cards populate via `.onAppear` /
  scan-tick `@State`, which a synchronous `ImageRenderer.render()` won't fire.
  Hence the off-screen real window + a short settle.
- **Widget views are compiled into the app target** (a `Widgets` source entry in
  `project.yml`, with the `@main` bundle excluded) purely so the generator can
  render them with fake `TimelineEntry` values. The widget views themselves stay
  in the `Widgets` package — they're widget-specific UI that *composes* shared
  `PacerUI` primitives, not shared UI. `@Environment(\.widgetFamily)` is
  read-only, so the gallery shows each widget's default (medium) layout.
- **Determinism.** No `Date.now`-relative randomness beyond a fixed hash
  (`noise(_:)`); data is keyed to the run's wall-clock so the time-windowed
  queries (today, last 30 days, six months) match, but the *shape* is stable.

### The rate-limit / pace data

The pace charts are the showcase feature, so the seed is deliberately shaped to
demonstrate them rather than draw a straight diagonal. `seedRateLimits` emits
samples across the **whole** cycle (from `cycleStart` at 0% up to "now") for both
windows, following keyframes (cycle-fraction → utilization %). Utilization is
cumulative within a cycle, so the curve only climbs — "falling back within pace"
means going *flat* while the ideal-burn reference line keeps rising. The
keyframes trace a burst that overshoots the pace line (ahead), a plateau that
lets pace catch up (behind), then another climb, so every colour band shows up.
To re-tune the story, edit the `keyframes` arrays in `seedRateLimits`.

## Adding or changing a scene

- **New view shot:** add a `capture(...)` call in `ScreenshotMode.captureAll`.
  Use `card: true` (+ `chrome: true, title:`) for window scenes, `card: false`
  for self-decorating views (widgets/status bar). Pass `width`/`height` for a
  fixed size or `nil` to size to the content.
- **New data a scene needs:** extend `ScreenshotMode.seed(...)`.
- **New widget:** add a fake entry to `ScreenshotEntries` and a tile to
  `WidgetGallery`.

## When to regenerate

**Re-run `make screenshots` after any meaningful UI change** to the dashboard,
history, menu bar, popover, or widgets, and **commit the updated PNGs in the same
PR**. It's also a step in the [release checklist](releasing.md) — the published
README and any store assets should match the version being shipped.
