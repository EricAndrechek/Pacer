# UX backlog

Things worth doing eventually but not blocking. Captured here so a
future session can pick them up cold without rediscovery.

## Hover-for-exact: extend the pattern beyond cost / tokens

The compact/exact pair landed for `pacerCost` / `pacerTokens` in
`fccba00`. Every visible cost/token now has `.help(pacerCostExact(v))`
or `.help(pacerTokensExact(v))` inline so hover reveals the full
locale-grouped value. A handful of other compact renderings in the
app would benefit from the same pattern, ranked by likely value:

1. **`pacerRelative` dates** — "3m ago", "yesterday", "2w ago".
   Loses precision; an absolute timestamp on hover
   ("2026-05-20 14:47:32") would let users disambiguate without
   checking another source. Used in the toolbar freshness pill,
   projects last-active column, sessions table, hover-row context
   menus, and probably others. Add a `pacerRelativeExact(date) ->
   String` companion and inline-sweep mirror of the cost pass.
2. **Pace-tile percent chips** ("5h 23%", "7d 91%"). Hover could
   reveal absolute counts ("32,847 of 137,500 messages") plus
   reset time. Implemented per-card since the underlying data
   differs (5-hour vs 7-day rate limit samples).
3. **Trend chips** ("+18% vs last week"). Hover could expand to
   "$12.4k → $14.6k vs prior 7d" so the user sees both endpoints
   without leaving the dashboard.
4. **Duration labels** ("9h 12m", "2d 4h"). Less critical — the
   compact form is already specific enough — but a tooltip with
   the exact `[start, end]` window could help on session detail
   modals.
5. **Cache reuse / hit-rate %**. Already inline-shown; hovering
   could reveal "read / written" raw totals (those are already in
   the subline, so lowest priority).

**Mechanical pattern:** every site looks the same as the
`Text(pacerCost(v)).help(pacerCostExact(v))` sweep — add a
companion exact function in `PacerCore/Sources/PacerUI/Formatters.swift`,
then run a targeted regex pass with `perl -i` to attach `.help(…)`
to every existing site. Keep the swept change *inline* — do not
introduce a `CostText`-style wrapper view. The wrapper pattern
triggered a SwiftUI runtime crash
(`_swift_getGenericMetadata` exhausting the stack guard) at scale
because every wrapper added new struct types to the view-tree's
generic stack. Inline `.help()` keeps the type tree the same
shape it had before, just one extra modifier per call.

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
