# Telemetry plan: Sentry crash reports + usage data

Status: PLAN, not built. Branch `exp/sentry-telemetry`, rebased on main aa7fbf7a (2026-11-02). Written 2026-10-21 from a code survey of
this tree, sentry-cocoa 9.30 source, Sentry docs, and live tests against the `ericandrechek/pacer`
project.

## Decisions already made (Eric, 2026-10-21)

- Sentry only for now. Evaluate adding PostHog after seeing what Sentry lacks.
- Crash reporting AND usage data are ON by default, each with its own Settings toggle.
- IP addresses are collected (`sendDefaultPii = true`) so we can see where users are.
- Sentry's own install ID is used (random UUID in its cache folder), no Pacer-made ID.
- Existing users get a release-note bullet and the README rewrite, no in-app notice.
- Apply for Sentry's open-source plan after the first release that carries this.

## Free plan fit

| Quota (Developer, monthly) | Expected use at ~100 installs | Guard |
| --- | --- | --- |
| 5,000 errors | crashes (rare) + hang/diagnostic reports | cap hang + MetricKit reports at 2 per Mac per day (`beforeSend`) → ≤ 6,000 worst case, typically far less; over-quota is dropped, never billed |
| 5M spans | 1 heartbeat/day + slow scan cycles (> 1 s, cap 20/day) ≈ 1M worst case | caps |
| 5 GB metrics | stall, click-lag, scan summary values | only stalls ≥ 250 ms; tiny |
| feedback | own category, not the error quota | — |
| sessions | not billed | — |

Limits that matter: 30-day retention (active-install history only goes back 30 days), no GitHub
integration (no automatic issues; email alerts work; `set-commits --local` still gives suspect
commits), no profiling, no Seer. The open-source plan lifts all of these.

## Verified so far

- Location: an error event sent with IP `{{auto}}` came back with `geo.country_code`,
  `geo.subdivision`, `geo.city` (test issue PACER-1, resolved).
- Query layer accepts `count_unique(user.id)` grouped by `release`, `user.geo.country_code`,
  `user.geo.city` on spans, and grouped by `release` on logs and metrics.
- Release-health sessions carry the install ID as `did` (SentryHub.m), so per-version user counts
  work without our own ID.
- NOT yet verified: hand-built test transactions (two attempts) never appeared, not even as drops.
  The real SDK is the first thing to prove (Phase 1 verification).

## Toggle mapping

- **Send crash reports**: crashes (signals, Mach exceptions, uncaught NSExceptions), app hangs,
  MetricKit hang/CPU/disk-write diagnostics, problem reports (in-app and `pacer feedback`).
- **Share usage data**: daily check-in (active installs, version, macOS, location, a feature
  snapshot, installed widgets, yesterday's window/menu opens and CLI command counts, yesterday's
  performance summary), release-health sessions, main-thread stall and click-lag metrics, slow
  scan-cycle traces.
- The SDK starts once if either is on, and every send hook (`beforeSend`, `beforeSendSpan`,
  `beforeSendMetric`) checks the live toggle, so flipping a toggle takes effect immediately without
  restarting the SDK (restart after `close()` is not documented as supported). Both off at launch:
  the SDK never starts.
- Never sent under either toggle: the user's Claude data (costs, tokens, project names, prompts,
  account emails), log lines, file paths.

## Where it runs

- Main app, normal launches only. Never in: screenshot mode, live render, tooltip self-test,
  cold-start probe, archive backfill/round-trip, account assign, test processes
  (`PacerPreferences.isTestProcess`), or with `PACER_TELEMETRY=off` in the environment.
- New central `LaunchMode` classifier replaces the four hand-written lists in
  `PacerAppDelegate` (`:92`, `:138`, `:317`, `:379`); telemetry gates on `.normal`.
- Not in the widget (sandboxed, no network entitlement) and not in the CLI process except the
  feedback send, which attaches the app's install ID read from the shared `cacheDirectoryPath`.
- Debug builds (`make install`) report as environment `development`, release `pacer@dev`; release
  builds as `production`, `com.ericandrechek.pacer@<version>+<build>`.
- DSN lives in `project.yml` as an Info.plist value (`PacerSentryDSN`); empty disables telemetry
  (forks building from source blank it).

## SDK configuration (sentry-cocoa, SPM product `Sentry`)

- `sendDefaultPii = true`, `environment`, `releaseName` as above.
- `enableAutoSessionTracking = false`; sessions are managed by hand (see "Sessions").
- `cacheDirectoryPath` = a `Sentry/` folder in the App Group container, so the install ID survives
  cache cleaners and the CLI can read it.
- Crash handler on; `enableUncaughtNSExceptionReporting = true`.
- App hangs: `enableAppHangTracking = true`, 2 s threshold (captures the main-thread stack during
  the hang, which our run-loop watchdog cannot). `enableMetricKit = true`. Both capped at 2 reports
  per Mac per day in `beforeSend`. Idle-CPU cost of Sentry's watchdog thread measured before
  shipping (perf invariant).
- Off: `enableSwizzling` (kills network/file auto-instrumentation in one go),
  `enableNetworkTracking`, `enableNetworkBreadcrumbs`, `enableCaptureFailedRequests`,
  `tracePropagationTargets = []`, `enableFileIOTracing`, `enableCoreDataTracing`,
  `enableAutoBreadcrumbTracking`, `enableUserInteractionTracing`, `enableAutoPerformanceTracing`,
  `attachScreenshot`, `attachViewHierarchy`. Logs product not used.
- `tracesSampler`: 1.0 for the heartbeat and selected slow-cycle transactions, 0 otherwise.
- `maxBreadcrumbs = 50`; breadcrumbs are curated only (tab switches, stalls, scan summaries,
  lifecycle), never `Log.write` lines (they carry project names and paths).
- Every hook runs `TelemetryScrubber`.

## Sessions

A Sentry release-health session is one stretch of the app running, ending clean, crashed or
killed. The Releases page derives everything from them: Macs active per version, adoption,
crash-free sessions, crash-free users. Sessions are not billed. The "user" is the install ID
(`did` = `SentryInstallation` id for `cacheDirectoryPath`).

Unit: **one session per Mac per local day, from the app process only.**

| Surface | Process | Sentry SDK | Sessions | How its use shows up |
| --- | --- | --- | --- | --- |
| Menu bar + dashboard window | the app (one process) | yes | one per app-day | window and menu opens counted locally, reported in the check-in |
| Widgets | sandboxed extension, no network | no | none | the app reports installed widgets (kind + size) from `WidgetCenter.getCurrentConfigurations` |
| `pacer` CLI | short-lived, run constantly by agents | no (feedback send only) | none | the CLI bumps a per-subcommand counter in App Group defaults (only when usage data is on); the app reports yesterday's counts |

App session lifecycle:
- Launch: `startSession()` if "Share usage data" is on.
- Local day change: `startSession()` again, which ends the previous one as `exited` and opens a
  new one. Driven by observing `PacerToday.shared.key` (existing `NSCalendarDayChanged` + wake
  handling), so no new timer. Slept through midnight: rotates on wake.
- Quit, including Sparkle's restart for an update: `endSession()` + `flush(timeout: 2)` in
  `applicationShouldTerminate` before replying. The relaunch opens a session on the new release, so
  adoption shows minutes after an update.
- Crash: on the next launch Sentry ends the open session as `crashed` and ties it to the crash
  event (`PreviousRunSessionFinalizer`). To confirm with auto-tracking off in the install test.
- Force quit, power loss, panic: closed as `abnormal` on the next launch.
- "Share usage data" turned off: `endSession()`; turned on: `startSession()`.

Why daily rotation: a Mac only counts as active in a window if it has a session there; one session
left open for weeks would drop running Macs out of "active in the last 24 h". Rotation also makes
crash-free sessions read as crash-free days, independent of how often people restart.

Rejected: Sentry's automatic sessions (start on `didBecomeActive`, so they count window activations,
not running Macs); one session per app run (stale active counts); sessions per sleep/wake (several
per day on laptops, noisy rates); SDK sessions in the CLI (session counts would track agent call
volume, and every call would pay SDK start + exit flush); SDK in the widget (needs a network
entitlement in a process WidgetKit starts and kills constantly). Known gaps: widget-extension and
CLI crashes are not reported.

## Signals

1. **Daily check-in**: one always-sampled transaction `app.heartbeat` per local day (at launch if
   not sent today, then at day rollover). Attributes: feature snapshot (menu bar style, number of
   accounts, API server on, skill installed, notifications on, cost mode, store size bucket) and
   yesterday's summary (scan cycles, p50/p95/max cycle ms, stalls ≥ 250 ms, max stall ms, click
   delay p95). Gives distinct active installs by version, macOS and location in one query.
   Fallback if traces can't carry location: release-health sessions for installs per version,
   plus one info-level event per Mac per week for location (~430 errors/month at 100 installs).
2. **Lag**: `MainThreadStallWatchdog` stalls ≥ 250 ms → metric `main_thread.stall_ms`
   (distribution); `ClickLatencyProbe` delivery delay → `ui.click_delay_ms`. Percentiles by
   version with no new timers.
3. **Slow scans**: cycles > 1 s (the existing `logIfInteresting` threshold) → a transaction with
   one child span per phase, rebuilt from `ScanReport.phaseTimings`; capped 20 per Mac per day.
   PacerCore emits through a small `TelemetrySink` protocol (no Sentry import in PacerCore).
4. **Crashes, hangs, diagnostics** as above.
5. **Problem reports**: Help → "Report a Problem…" sheet → `SentrySDK.capture(feedback:)`; and
   `pacer feedback` POSTs a `feedback` envelope with the DSN (scrubbed, ≤ 4096 chars, 3 s timeout,
   falls back to today's local inbox + issue link). Off with `--local`, `PACER_FEEDBACK=local`, or
   the crash-reports toggle. This replaces #290's Worker + GitHub App design.

## Scrubbing (`PacerCore/Util/TelemetryScrubber.swift`, pure, unit-tested)

- `/Users/<name>/…` and the home directory → `~/…`; Claude's dashed project dirs
  (`-Users-<name>-…`) → `<project>`; emails → `<email>`; `Bearer …`, `sk-ant-…`, `sk-…`,
  `ghp_…`, `github_pat_…`, hex ≥ 32 and base64 ≥ 40 → `<redacted>`.
- Applied to event message, exception values, breadcrumbs, tags/contexts, span descriptions and
  data, metric attributes, feedback text.

## Release pipeline

- `project.yml`: `DEBUG_INFORMATION_FORMAT: dwarf-with-dsym` for Release explicitly.
- `release.yml`, after the build: install pinned `sentry-cli`; `debug-files upload` of
  `build/Build/Products/Release`; `releases new` / `set-commits --local` / `finalize` with the same
  release string the app reports. Skipped on `dry_run` or when `SENTRY_AUTH_TOKEN` is absent.
- New secret `SENTRY_AUTH_TOKEN` (org token); add to `bin/setup-release-secrets.sh` and
  `docs/releasing.md`.

## Settings UI

New "Privacy" section with one `PacerCard`: two toggles ("Send crash reports", "Share usage
data") and one line linking to the README's privacy section. Terse copy.

## Text to rewrite

README privacy section (exact list per toggle, IP + approximate location, Sentry as processor,
how to turn off, corrected network list incl. `models.dev`, `raw.githubusercontent.com`, `huggingface.co` (forecast weights), `ericandrechek.github.io` (appcast + price history), Sentry),
README:86, `AboutView.swift:96`, `Skills/pacer/SKILL.md:29` and `Pace.swift` "nothing is sent",
`docs/ios-multidevice-sync.md:11`, release-note bullet, and a new AGENTS.md "Telemetry" section
with the invariants (what may be sent, never forward `Log`, scrubber, `LaunchMode` gate, tests).

## Build order (one PR, one commit per step)

1. PacerCore foundations: `LaunchMode`, telemetry pref keys (absent = on), `TelemetryScrubber`,
   `TelemetrySink`, daily scheduler + per-day caps, feedback envelope builder. Tests.
2. App: Sentry package, `TelemetryController` (options, hooks, sessions, heartbeat), DSN plumbing,
   start in `PacerAppDelegate.init` after `registerDefaults()` (normal launch only), flush on quit,
   Privacy settings card.
3. Signals: stall + click metrics, slow-scan transactions, daily summary, curated breadcrumbs.
4. Release pipeline: dSYM upload + releases, secret setup docs.
5. Problem reports: in-app sheet + `pacer feedback` send.
6. Text: README, About, AGENTS.md, SKILL.md, release-note bullet.

## Verification

- `make test`, `make verify` after each step. No app launches by the builder.
- Eric installs the branch build (sequenced with other sessions' installs), uses it normally, then
  triggers a test crash (debug-only Help menu item). I check through the Sentry MCP: heartbeat with
  location, session and crash-free rate, the crash, stall metrics, a test problem report. Idle CPU
  compared with `make perf-snapshot` before and after.
- Symbolication is confirmed on the first release build (dev builds have no uploaded dSYMs).

## After it ships

Apply at sentry.io/for/good; build the Sentry dashboard (active installs by version, installs by
country, crash-free by version, stall p95 by version, slow scans by phase); then decide on PostHog.
