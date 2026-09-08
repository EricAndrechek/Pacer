# UX backlog

Things worth doing eventually but not blocking. Captured here so a
future session can pick them up cold without rediscovery.

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

**Do not try to verify this with a scripted hover.** An attempt to test
option 1 by dispatching AppKit mouse events at a real window took over the
repo owner's cursor mid-work; see "Never take over the machine" in
`AGENTS.md`. There is no off-screen way to test `NSMenu` tracking, which
means this item cannot be closed by an agent alone: build the change if
you like, then hand it to a human to hover. "This needs a human to check"
is the correct place to stop.

Two relative-date labels in `MenuBarContent.swift` are deliberately left
without the `pacerRelativeExact` tooltip the rest of the app now carries,
for this reason — `.help` would not fire on them anyway.

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
