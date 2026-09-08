# UX backlog

Things worth doing eventually but not blocking. Captured here so a
future session can pick them up cold without rediscovery.

## Should the limit tables live in DuckDB? Measured answer: no longer worth it

The instinct is right — `RateLimitSample` and `UsageLimitSample` are append-only
time series, tens of thousands of rows, read as bulk 32-day ranges by the
forecast. That is an analytical workload in a row store, and this project
already has the pattern for it: token samples live in a DuckDB archive with a
hot window in SwiftData.

They are in SwiftData for two reasons that still hold — the widget extension
reads them through the App Group, and `@Query` reactivity is what makes the
gauges update when a poll lands — and one that stopped holding: they used to be
small. At the old five-minute poll cadence this was ~300 rows a day. Adaptive
multi-token polling took it to ~60 seconds and the second account doubled it
again, which is how a design note reading "~1.1 s per refit" ended up
describing something that took sixteen.

**But the cost was never the storage engine.** It was SwiftData materialising
75,000 rows as objects at ~65 µs each. Reading the same file directly through
sqlite3 (`RawLimitReader`) took the two fetches from 3,618 ms + 1,485 ms to
128 ms + 22 ms. What remains of a refit is `evalRows` and `makeFit` — the
modelling — and a move to DuckDB would now be competing for about 150 ms out of
2,700 ms.

So: worth doing if the tables are ever moved for storage reasons, and not worth
doing for speed. If they do move, `RawLimitReader` is deleted rather than
ported.

## The engine refit was the most expensive thing Pacer does — where the time went

**This is the cause of the multi-second dashboard hitches.** 30 of 36 loads
over a second happened *during* a refit, 6 outside. Measured across a day on a
two-account store: 97 refits, median 15.9 s, worst 41 s, half an hour of work.

`recompute` now logs its phases when it exceeds a second. A representative
steady-state line for the active account's ~45,000 scoped rows and ~30,000
rate rows over the engine's 32-day window:

    recompute all 7040ms {scopedLimits:3364, rate:1332, evalRows:775,
                          makeFit:700, snapshots:112, features:78,
                          hourly:66, daily:9}

Two thirds of it is two fetches. `makeFit` — the actual modelling — is 700 ms.

**Fixed.** The two big fetches now go through `RawLimitReader` — 7,717 ms →
2,669 ms for a whole refit. Also: only scopes something still reads are
refitted (`EngineHost.live`). On a machine where the dashboard has been scoped to an
account at some point, that was up to two thirds of the work.

**Tried and rejected, with numbers, so nobody repeats them:**

- *Serialising the refits.* One engine fits in ~13.2 s, three concurrently in
  ~15.9 s — they overlap almost perfectly, so serial would stretch the window
  the rest of the app waits on from ~16 s to ~40 s for identical work.
- *`propertiesToFetch` on the two big fetches.* The obvious columnar
  projection, and it is **slower** on these queries: rate 1.10-1.33 s →
  1.56-1.79 s, scoped 2.86-3.36 s → 3.62-4.57 s, consistently. The pace card's
  loader does benefit from the same API, so it is a property of these queries,
  not of SwiftData.

**The next lead, attempted and backed out — read this before retrying.**
`.allAccounts` reads the *active* account's limits by design (two 5-hour
windows do not sum), so when that account's own scope is also live the two
engines run identical `fetchRate` and `fetchScopedLimits` calls in the same
cycle. Confirmed rather than assumed: the refit line now logs `limitAcct:`, and
`recompute all` and `recompute 8c95` both report `limitAcct:8c95` while each
spends ~3.7 s on `scopedLimits`. That is one whole duplicate copy of the
expensive half of a refit, every cycle.

A shared read was built and removed again. Two things it taught:

- **An ordinary cache cannot help.** The engines refit *concurrently*, so
  check-then-build has both miss before either stores anything — measured,
  `share:0h` on every cycle. It needs single-flight: the second caller waits on
  the first's result instead of issuing its own query. Wall time is unchanged;
  the store does half the work, and the store is the contended resource.
- **Test isolation is the hard part.** `.serialized` orders tests inside a
  suite, not across suites, and Swift Testing runs suites in parallel — so any
  process-wide cache is being mutated by the engine tests while its own tests
  run. The single-flight test stayed intermittently red (`builds → 3` instead
  of 1) and the reason was never pinned down. It was reverted rather than
  shipped: a concurrency primitive whose test cannot be trusted is worse than
  the duplicate fetch.

If you pick this up, key the cache per engine-host instance rather than
process-wide, or inject it, so the tests are not fighting over global state.

After that, the real question is why 32 days of 60-second samples are read at
full resolution when the fit works in cycles. That one is gated on the golden
fixture — changing what the fit sees has to stay byte-identical for the active
account — so it needs the Python replay harness, not a hunch.

## What is left after the refit fix: the scan path

With the refit down from ~16 s to ~2.8 s, the remaining main-thread stalls
change character. Over the first quarter hour after the fix: 4 refits (p50
2,820 ms), 13 series loads (p50 98 ms), and 6 stalls of a second or more — and
all six sit inside a two-minute window dense with `[ScanCoordinator] scan:
incremental` lines, with a pace-card top-up of *three rows* taking 2,215 ms in
the middle of it.

So the next contended writer is the JSONL scan path, not the engine. Two
caveats before anyone acts on that: the sample is fifteen minutes, and it was
taken while the machine was generating Claude Code turns continuously, which is
the heaviest the scanner ever gets. Measure over a normal day first.

## The pace card's series load is occasionally slow — it is the refit above

Measured over a full day on a two-account store, with the dashboard open:

    PaceChartCard series loads: n=544  p50=183ms  p90=751ms  max=3329ms
    over 1s: 34 (6%)

The slow ones line up with the multi-second main-thread hitches — about 29
stalls of 2s or worse across the day, roughly one an hour, worst 5.7s. Not
install churn: the overnight hours, with nobody touching the machine, look the
same as the busy ones.

**Ruled out: contention with the poller's writes.** That is the obvious guess
and it is wrong — slow loads sit within 3s of an `[OAuthPoller]` write 35% of
the time, fast loads 39%. No relationship.

**Answered.** The per-fetch logging (`fetch=[8c95 top-up 3row 61ms | …]`)
showed the slow ones are not cold reads: a *top-up fetching three rows* took
2,224 ms. What they have in common is the engine refit above — the card's read
queues behind it. Fix the refit and this goes with it; there is nothing wrong
with the loader itself.

Ruled out along the way: contention with the poller's writes. Slow loads sit
within 3 s of an `[OAuthPoller]` write 35% of the time, fast loads 39%. No
relationship.

## Hover-for-exact: the pace tiles, and only the pace tiles

The compact/exact pair landed for `pacerCost` / `pacerTokens` in
`fccba00` and for relative dates (`pacerRelative` /
`pacerRelativeExact`) in the follow-up sweep. Session duration
(hover → `first seen → last seen`), the cache sub-line (hover →
exact read / written counts) and the week-over-week tiles (hover →
`$4,203.11 → $14,602.55`) went with it. What is left is one item,
and it is smaller than it first looked:

**Pace-tile percent chips** ("5h 23%", "7d 91%"). The original note
here asked for hover to reveal absolute counts — "32,847 of 137,500
messages" — plus the reset time. Neither is available as written:

- Pacer has no numerator or denominator to show.
  `PaceChartCard.Column` carries `usedPct` and nothing else, because
  Anthropic's rate-limit headers report a percentage, not a count.
  Recovering counts would mean inferring a denominator, which is a
  guess dressed up as a fact — exactly what the hover-for-exact
  pattern exists to avoid.
- The reset time is already rendered, in the `caption` directly
  under the chip (`pacerResetCaption` → "resets in 2 hr. · 9:14 PM").

So the honest remaining version is small: hover the rounded hero
percent to see the un-rounded one (23% → 23.4%). Worth doing on a
pass that is already touching `PaceChartCard.swift`; not worth a
dedicated change to a file that is churned heavily by scope work.

**Mechanical pattern** (still the rule for any future sweep): add a
companion exact function next to the compact one in
`PacerCore/Sources/PacerUI/Formatters.swift` or `TimeFormatters.swift`,
then attach `.help(…)` to the existing call sites. Keep the swept
change *inline* — do not introduce a `CostText`-style wrapper view.
The wrapper pattern triggered a SwiftUI runtime crash
(`_swift_getGenericMetadata` exhausting the stack guard) at scale
because every wrapper added new struct types to the view-tree's
generic stack. Inline `.help()` keeps the type tree the same shape
it had before, just one extra modifier per call. Where a surface
already takes a `tooltip:` parameter (`MetricTile`), use that
instead of wrapping it.

Two sites are deliberately left without tooltips: `MenuBarContent`'s
popover rows, where `.help` never fires (see the next section), and
the status-item button, which is itself already the hover surface.

## Menu-bar popover (NSMenu) doesn't fire SwiftUI tooltips

The `MenuStatusContent` view that drops down from the status-bar
button is hosted inside an `NSMenuItem.view` via `NSHostingView`.
`.help(_:)` on the rows there doesn't fire on hover — `NSMenu`'s
own tracking dominates: it highlights the menu row, but the
hover-help timer that SwiftUI's `.help()` modifier relies on never
runs because the cursor never settles inside the hosted SwiftUI
content the way it does in a regular window.

We added a `tooltip:` parameter to `todayValueRow` anyway so the
plumbing is ready when a workaround lands. Options for a real fix
when this matters:

- **`NSToolTipManager.shared`** — manually register tooltip rects
  on the underlying `NSHostingView`. Requires bridging from the
  SwiftUI side via an `NSViewRepresentable` wrapper that exposes
  the host view, then calling `addToolTipRect` on each row's
  frame. Tracking frame changes as the popover resizes is the
  fiddly part.
- **`NSMenuItem.toolTip`** — works for stock NSMenu items, but our
  popover content is a single hosted view, not a stack of menu
  items, so the tooltip would apply to the whole panel rather
  than per-row. Not useful as-is.
- **Drop NSMenu entirely** for the data panel. Render an
  `NSPanel` (or a SwiftUI popover anchored to the status item)
  that hosts the same `MenuStatusContent`. SwiftUI's `.help()`
  fires normally in a real window. Trade-off: lose the
  native-NSMenu look and the right-click submenu integration.

The status item *button* itself shows a tooltip on hover (Apple's
status-item HIG path) via `.help(tooltip)` on `MenuBarLabel`. That
covers the most common discovery path. The popover content stays
visible while open; users wanting exact numbers can open the main
app from the same panel.

**Option 1 was built, measured, and does not work. Do not rebuild it.**

`NSView.toolTip` was applied alongside `.help` via a SwiftUI-sized overlay —
the appealing version of option 1, with no manual `addToolTip` rects and so no
frame tracking to go stale as the popover resizes. It was verified on a real
session with `make verify-tooltip`, which lands the pointer on a row and asks
the window server whether a window appeared:

    HOVER: landed on the row
    TOOLTIP: no — no window appeared while hovering

The hover is proven, so the negative is real: **NSMenu swallows AppKit's own
tooltips exactly as it swallows SwiftUI's.** The mechanism was reverted rather
than shipped, because dead code that reads as working is worse than the gap.
`.help(...)` stays on those rows — harmless, and correct everywhere else the
same view could be hosted.

That leaves **only option 3**: stop using `NSMenu` for the data panel. It
changes how the menu bar looks and how it hands off to other menu-bar items,
so it is a product decision, not a spare afternoon. Nobody should spend
another authorised run on options 1 or 2.

`bin/verify-menubar-tooltip.sh` and `MenuBarTooltipSelfTest` are kept: they
are the pattern for anything else that can only be answered on a real session
— a scripted one-shot, a machine-readable verdict, and the owner's go-ahead
for that run. Read `AGENTS.md` § "Never take over the machine" before using
them.

## Other things noticed during the formatter sweep

- **`pacerCost` / `pacerCostExact` currency localization scaffolding**
  is in place via `pacerDisplayCurrencyCode` and
  `pacerCurrencySymbol(for:)` but currently hard-wired to USD /
  "$". A Settings → Display Currency picker that writes to a
  shared `@AppStorage` is the obvious next step, plus an FX
  conversion shim (probably `convertFromUSD(usd:to:) -> Double`)
  called at the top of both formatters. Out of scope for v1 but
  the threading is ready.
- **Widgets stay compact-only** — no hover affordance on the
  Notification Center / home screen. Correct by design.
- **CSV exports** already use raw `Double` values (not `pacerCost`),
  so they're unaffected by the compact change. Worth a sanity
  check if anyone ships a new export.
