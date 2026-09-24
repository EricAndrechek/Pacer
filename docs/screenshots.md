# Screenshots

The README images in `docs/screenshots/` are **generated, not hand-captured** —
the real app renders against synthetic data and writes deterministic PNGs. This
keeps them in sync with the UI and makes them a first-class, repeatable part of
the dev/release cycle.

**The committed images come from CI.** Marking a draft PR **ready for review**
runs the *README screenshots* workflow, which renders on a `macos-26` runner — the
SDK releases are built with, so the images show the chrome users get — and
pushes a `docs: regenerate README screenshots` commit onto that PR's branch, to
be reviewed with the change it illustrates. Nothing is captured from anyone's
screen, only synthetic data is ever rendered, and no artifacts are kept. To run
it by hand: `gh workflow run screenshots.yml --ref <branch>` (on `main` it parks
the commit on an `automation/readme-screenshots-*` branch instead).

**A local preview** (written to the gitignored `screenshots/preview/`, never to
`docs/screenshots/`):

```sh
make screenshots APPROVED=1
```

It captures the screen — invisibly: the window sits beneath the desktop picture
and is never activated — so, like `make record`, it runs only with the owner's
go-ahead (AGENTS.md). Traffic lights are grey in a preview: only a key window
has colour, and a preview never takes focus.

## What it produces

| File | Scene | Notes |
| --- | --- | --- |
| `dashboard.png` / `dashboard-dark.png` | Main dashboard | the app's real window — title bar, toolbar, sidebar; light + dark |
| `history.png` / `models.png` | History, Models tabs | real window |
| `projects-collections*.png` | Projects tab, unscoped and scoped to a collection | real window |
| `menubar.png` / `menubar-dark.png` | Menu bar with Pacer's menu open | the real status item and its real `NSMenu` (native Open / Settings / Quit items) in the real menu bar, captured in CI with the system in light, then dark, mode; local previews skip it |
| `widgets.png` | Widget gallery | one composite of the real widget views (Today, pace gauges, live session, daily cost, top projects) |
| `share-card.png` / `share-card-dark.png` | Share-image export (`App/Share`) | the branded 7-day pace card from the in-app "Share…" action, via the same `ImageRenderer` path; light + dark |

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
3. **Capture — window scenes.** The dashboard, History, Models and Projects
   shots are the app's **real window**: the `Window("Pacer", id: "main")` scene
   hosting `ContentView` over the seeded container, switched to the right tab.
   `bin/pacer-screenshot-capture.swift` — a separate process, started by
   `bin/dev-screenshots.sh` — photographs it through the window server with
   ScreenCaptureKit. So the title bar, traffic lights, toolbar capsules, sidebar
   and shadow are whatever macOS draws for Pacer. They used to be a hand-drawn
   copy (`MacWindowChrome`) that drifted from the real thing again and again
   (#128). The helper is a separate process so that Pacer.app itself never
   needs the Screen Recording permission. In CI it also adds a 2× virtual
   display (the runners only have a 1× one) and the window is made key; locally
   the window goes beneath the desktop picture, unactivated.
4. **Capture — everything else.** Cards, the menu bar, widgets and the share
   card have no window chrome to get wrong, so they are still rendered from the
   views: each **real** view hosted in an off-screen, never-activated window so
   the full SwiftUI lifecycle runs (`@Query` fetches land, `@State` caches
   refresh, Charts lay out — a one-shot `ImageRenderer` pass renders empty
   cards), then snapshotted to a PNG.
5. **Exit.** The process exits when done, non-zero if any scene failed.

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

- **New window shot:** add a `captureRealWindow(...)` call in
  `ScreenshotMode.captureAll` with the window size, appearance and tab. Never
  draw window chrome by hand — that is what #128 removed.
- **New view shot:** add a `capture(...)` call. Use `card: true` for cards,
  `card: false` for self-decorating views (widgets/status bar). Pass
  `width`/`height` for a fixed size or `nil` to size to the content.
- **New data a scene needs:** extend `ScreenshotMode.seed(...)`.
- **New widget:** add a fake entry to `ScreenshotEntries` and a tile to
  `WidgetGallery`.

## When to regenerate

**Every UI PR gets fresh images when it is marked ready for review** — review
that commit with the rest of the change. For a UI change that went in without
them, run the workflow by hand. It's also
a step in the [release checklist](releasing.md) — the published README and any
store assets should match the version being shipped.
