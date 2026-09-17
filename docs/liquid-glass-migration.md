# Moving releases to the macOS 26+ SDK (Liquid Glass)

**Status: done.** Decided and executed 2026-09-17, in the same PR that fixed the
macOS 26+ regressions. Kept as the record of what was weighed, what it cost, and
which options were rejected — the reasoning is the part worth having later, not
the diff.

## What this is actually about

macOS applies Liquid Glass only to binaries linked against the macOS 26 SDK or
later. It is a property of the build, not of the machine running it — the usual
linked-on-or-after gate. Pacer ships from `macos-15` runners, so released builds
carry `DTSDKName = macosx15.5` and render in the pre-Liquid-Glass design even on
macOS 27. Nothing is broken; the app has simply never linked against an SDK that
offers the new design, and there is no Liquid Glass code in the tree.

So "migrating" is one runner change plus the fallout it exposes. There is no
adoption work in the sense of rewriting views — the system restyles native
controls on its own.

## The mechanical change (done)

```diff
# .github/workflows/release.yml
-    runs-on: macos-15
+    runs-on: macos-26

# .github/workflows/ci.yml — the app-build job
-    runs-on: macos-15
+    runs-on: macos-26
```

`macos-26` is GA and ships Xcode 26.x. Note that is **SDK 26, not 27** — CI's
output is not byte-identical in appearance to a local Xcode 27 build, though
both are Liquid Glass. There is no `macos-27` label — GitHub ships macOS 27 as
`xcode-27` / `xcode-27-xlarge` (arm64 only), and as of 2026-09-17 that is public
preview with no announced GA date. So the screenshots in
`docs/screenshots/` (rendered locally against SDK 27) run marginally ahead of
what CI produces. Re-render them from a CI-matching toolchain if that ever
visibly matters; it did not at the time of writing.

Both are pinned, deliberately **not** `macos-latest`: that label moves on
GitHub's schedule, and the runner is the one setting that silently restyles the
whole app.

The PacerCore test job already runs on both images and should stay that way: it
is the OS-divergence canary, not a build-appearance choice.

`MACOSX_DEPLOYMENT_TARGET` stays **15.0**. The macOS 27 SDK's floor is 13.1, so
building against a new SDK drops no one — a single binary still serves macOS 15
users, who keep the appearance they have today because their AppKit has no glass
to draw. **Nobody on an older macOS loses anything.** This is worth being
explicit about, because "new SDK" reads like "drops old OSes" and here it does
not.

## What it costs

### Control metrics, not aesthetics

The risk is not that glass looks bad; it is that native controls get taller and
rounder, and Pacer's layouts are dense. Inventory taken 2026-09-16:

| Surface | Count |
| --- | --- |
| `.controlSize(.small)` | 51 |
| `.textFieldStyle(.roundedBorder)` | 11 |
| `.pickerStyle(.segmented)` | 7 |
| bordered / borderedProminent buttons | 5 |
| `.menuStyle(.borderlessButton)` | 4 |

Everything else — charts, donuts, pace bands, the menu-bar readout — is
custom-drawn `Canvas`/`Shape` work and is unaffected by the design change.

### What has already been checked on SDK 27

Rendered off-screen from an SDK-27 build and diffed against the SDK-15 baseline:

- **Dashboard, History, Settings: clean.** No clipping, no overflow, no
  overlapping controls. Settings is the control-dense one (sliders, popups,
  toggles, checkboxes) and it holds up.
- **Collections editor: improved.** The old hard black focus rectangle on the
  colour swatch became the new soft focus ring.
- **One real regression, already fixed** on `fix/macos-27-url-identity`: Swift
  Charts stops honouring `AxisMarks(values:)` on a band axis from macOS 26 on,
  which drew all 90 dates of the Models trend on top of each other. Fixed via
  `PacerDateAxis.labelIfMarked(_:)`, which behaves identically on macOS 15.

### What has NOT been checked

- **The menu-bar status item.** A custom `NSStatusItem` hosting a SwiftUI view,
  and macOS 26+ changed menu-bar translucency. `menubar.png` is a synthetic
  composite render, not the real item — it proves nothing here. Needs a human
  look on a machine running an SDK-26+ build.
- **Widgets under the real widget host.** The screenshot harness renders widget
  *views* in-process. It says nothing about the installed `.appex` running under
  the system widget daemon, which is exactly where this project has been bitten
  before (v0.3.10 → v0.3.11).

### Checked by the maintainer on an SDK-27 build (2026-09-17)

- **Menu-bar item: looks right.** Renders correctly, no clipped chips, and the
  click-down menu works.
- **Menu-bar tooltip: did not appear.** Unresolved — see below. It is a real
  feature (`MenuBarContent.swift`, `.help(rendered.tooltip)`), added precisely
  because Apple's Battery / Wi-Fi / Volume items all show one and ours did not.
- **Widgets: install and render, with visibly less contrast.** Measured rather
  than eyeballed. `PacerDesign.cardBackground` is
  `NSColor.controlBackgroundColor`, which in dark mode resolves to an **opaque
  rgb(30, 30, 30)**. Sampling the maintainer's screenshot of a live widget gives
  **rgb(42, 42, 42) to rgb(60, 59, 59)**, varying top-to-bottom. An opaque flat
  fill cannot produce a gradient, so the macOS 26+ widget host is compositing its
  own material with our container background rather than drawing it as specified.
  The card lands 40–100% lighter than designed, which is what costs the white and
  green text its separation.

  This is only reachable from an SDK-26+ build, so released builds are
  unaffected — it is a migration cost, not a live bug.

  **Decided 2026-09-17: accept it.** This is how macOS renders widgets now, and
  every other app's widgets get the same treatment, so matching the platform is
  worth more than holding the original contrast. No code change; do not "fix"
  this later without revisiting the decision.

  Rejected, and why they are recorded rather than deleted: giving widgets an
  explicit opaque colour would make Pacer's widgets deliberately unlike every
  other widget on the system, and the host may composite over it anyway; raising
  widget text contrast only would be fighting the same material from the other
  side. Note also that `cardBackground` is shared with every dashboard card **by
  design** ("mirrored to the widget container background so the panel and the
  dashboard cards blend"), so either would have needed a widget-local colour and
  a deliberate decision to let the two diverge.

Both must be signed off before shipping, and neither can be automated.

## The one-way door

`UIDesignRequiresCompatibility` is **ignored** when building against the macOS 27
SDK. Opting back out means building with an older Xcode, not setting a key.

That matters more than it looks, because **Xcode 16.4 and the macOS 15 SDK are no
longer on the maintainer's Mac** — Xcode 27 ships only `MacOSX27.sdk`. Rolling
back locally would require downloading an older Xcode from Apple. CI is the
actual escape hatch: as long as `release.yml` pins an image, the runner decides
the shipped appearance, and reverting the runner reverts the design. Keep that
pin explicit and never let it drift to `macos-latest`.

## Screenshots

`docs/screenshots/` ships in the README, so it has to be regenerated from a build
whose SDK matches what releases use — otherwise the README shows users chrome
they do not have. Today they are deliberately held at the SDK-15 baseline for
exactly that reason.

Sequence matters: **move the runner first, then regenerate**, not the other way
round. `make screenshots` is one command and takes under a minute, so this is
bookkeeping, not work — it just has to happen on the right side of the switch.

Note the synthetic data is seeded relative to the current date, so a regenerated
set always differs from the old one in numbers and weekday names even when
nothing visual changed. Do not read that as layout drift; diff the pixels.

## Versioning

The repo convention is minor = SwiftData-reset breaking, patch = additive UX.
This is neither: no schema change, no new feature, but the app looks materially
different on macOS 26+. Precedent exists for breaking the convention
deliberately — v0.4.0 was a non-reset minor for the rate-limit milestone.

Recommendation: **minor**, with release notes that lead on the appearance change
so nobody on Tahoe thinks their install broke. Say plainly that macOS 15 users
see no change.

## Checklist — completed 2026-09-17

1. Confirm the menu-bar item and widgets look right on an SDK-26+ build — the
   two unautomatable checks above.
2. Flip `release.yml` and `ci.yml`'s `app-build` to `macos-26`. Leave the
   PacerCore matrix alone.
3. Green CI on both images.
4. `make install`, walk the dense surfaces once more at the runner's SDK.
5. `make screenshots`, diff the pixels, commit.
6. Version bump + release notes leading on appearance.
7. Ship; verify the released app reports `DTSDKName = macosx26.*`.

## Open questions

- ~~Wait for a `macos-27` runner image so CI and local builds agree on SDK, or
  accept SDK 26 from CI while developing against 27?~~ **Settled 2026-09-17:
  accept SDK 26 from CI.** The `xcode-27` image exists but is public preview,
  and a preview image can be rebuilt or withdrawn under us — not something to
  put on a path that signs, notarizes and publishes an auto-update. Revisit if
  and when it reaches GA. Since Liquid Glass landed in 26, SDK 27 buys no
  appearance difference in the meantime; the only gap it would close is that
  local screenshots render marginally ahead of CI.
- Is there any appetite for *actively* adopting glass (`.glassEffect`,
  `GlassEffectContainer`) on Pacer's own cards, or is passive restyling of native
  controls the whole intent? This plan assumes passive only.
