# Telemetry plan: Sentry crash reports + PostHog usage data

**Since 2026-11-03 (two tools, two toggles):** Sentry carries crashes, hangs,
MetricKit and performance; PostHog carries usage data. The current toggle
model, migration and full PostHog event list are in "Two toggles" and
"PostHog" below; older sections are kept as the record of how it got here, and
where they say "Share usage data" about Sentry, read "Crash reports and
performance".

## Two toggles

Settings → Privacy, card "Sharing with Pacer", both on by default, both read on
every send (`TelemetryConsent.state`):

| Toggle | Key | Tool | Covers |
| --- | --- | --- | --- |
| Crash reports and performance | `pacer.telemetry.crashReports` | Sentry | crashes, hangs, MetricKit, problem reports, performance metrics and spans, forecast accuracy, release-health sessions, the minimal check-in |
| Usage data | `pacer.telemetry.usageData` | PostHog | every event in "PostHog" |

"Performance" inside the first toggle is `TelemetryConsent.State.performance`:
the crash toggle, unless the migration hold is set.

**Migration (one time, `pacer.telemetry.migratedTwoToggles`).** In the first
release the usage key also covered Sentry's performance data. If it was
explicitly off at upgrade, `pacer.telemetry.performanceHeld` is set: PostHog
stays off (same key) and Sentry sends only crashes, hangs, MetricKit and
problem reports (no metrics, spans, sessions or check-in). The hold ends the
first time the user changes either Privacy toggle. Matrix (old crash × old
usage → crashes / performance / usage): absent or on × absent or on → on/on/on;
on or absent × off → on/off/off; off × anything → off/off/(usage as stored).
Tests: `TelemetryConsentTests`.

**What moved from Sentry to PostHog (2026-11-03):**
- the check-in snapshot's usage fields: `settings.*`, `clients.*`,
  `accounts.*`, `usage.*` (peak bands, hit/forecast flags, models used, token
  magnitude), `widgets.*`, `lifecycle.*`, `env.*` beyond macOS and model,
  `install.*`, `models.present`, `counter.*`;
- the usage counters as Sentry metrics: `ui.*` (tabs, menu, window, modal,
  report problem, alert clicks; not `ui.click.delay.*`), `intent.*`,
  `api.route.*` (`CounterRouting.isUsage`).

**What Sentry keeps:** crashes, hangs, MetricKit, problem reports, sessions,
the `pacer.checkin` span and `checkin.snapshot` metric with only
`checkin.day`, `env.macos`, `env.model`, `env.model_name`, `build.config` (the
release is the version), all performance metrics and spans (stalls, click
delay, slow scans, rebuilds, downloads, arena passes, CLI durations, widget
timeline times, `energy.cpu_seconds`), forecast accuracy, and the health
counters (`data.*`, `oauth.*`, `cred.*`, `telemetry.*`, `main_thread.*`,
`api.snapshot_ms.*`, `ui.click.delay.*`).

## PostHog

**Client.** Our own, `App/Telemetry/PostHogClient.swift`: an on-disk queue
(App Group `PostHog/queue.json`, at most 1,000 events) posted to
`<host>/batch/` in batches of 100, 30 s after the first queued event or at
once past 20; no timer while the queue is empty; 2xx or a non-429 4xx removes a
batch, anything else backs off (5 min doubling to 1 h); one bounded (2 s)
send on quit; the toggle going off discards the queue. Not posthog-ios: its
SPM package supports macOS but links a vendored PLCrashReporter (a second
crash reporter beside Sentry's), libwebp for session replay, and has
swizzling and remote-config / feature-flag fetches on by default; we would
still have to wrap every call for the caps, the scrubber, the live toggle and
per-event timestamps. So: no session recording, no autocapture, no surveys or
feature flags, no SDK lifecycle events; every event below is ours.

**Config.** `PacerPostHogToken` / `PacerPostHogHost` in Info.plist from
`PACER_POSTHOG_TOKEN` / `PACER_POSTHOG_HOST` in `project.yml` (the token is
public by design, like the DSN; either empty → no PostHog). GeoIP from the
request IP is wanted and the project keeps anonymize_ips off.

**Identity.** `distinct_id` = Sentry's install id (`INSTALLATION` in
Sentry's App Group cache folder; created in Sentry's format if Sentry has
not run, `AnalyticsIdentity`), so one Mac is the same in both tools.

**Sentry → PostHog link.** While Usage data is on, every Sentry event carries
a `posthog` context whose `url` is that Mac's person page,
`https://us.posthog.com/project/678727/person/<install id>`
(`PostHogPersonLink`, set and cleared with the toggle in
`TelemetryController.syncPostHogLink`). A context rather than a tag because
Sentry renders a context URL as a link and a tag as a search filter. The id
is the random install id Sentry already holds, so the link adds nothing
identifying. `TelemetryScrubber` exempts exactly this URL shape (its
long-token rule would otherwise redact it); `TelemetryScrubberTests`.

**Every event** carries `distinct_id`, `$lib` (`pacer-macos`),
`$lib_version`, `$os`, `$os_version`, `$app_version`, `$app_build`,
`build.config` (`debug` / `release`; the maintainer's Mac is filterable),
`$process_person_profile`.

**Gates and caps.** `LaunchMode.isNormalLaunch` and not `PACER_TELEMETRY=off`
(no PostHog in tests, renders, probes, self-tests); the Usage data toggle on
every capture and every send; `TelemetryBudget.takeAnalytics`: 500 events a
day per Mac (debug 100), 100 per event name (debug 30), `tab_viewed` and
`menubar_opened` 200 (debug 50); `daily_checkin` and `widget_inventory`
exempt. Drops counted as `telemetry.capped.analytics` and
`telemetry.capped.analytics.<name>`, which the next check-in carries.

**Cleaning** (`AnalyticsPayload`, the last step before the queue): keys naming
forbidden data are dropped (`email`, `path`, `prompt`, `account_id`,
`org_id`, `project`, `cost_usd`, `message`, …); strings go through
`TelemetryScrubber`, then UUIDs → `<id>`, file paths → `<path>`, 200 chars
max. Constructors (`AnalyticsEvents.swift`) take enums; names outside a known
list become `other`, free strings are tokenized (`[a-z0-9_.:+-]`).

**Person properties** (`$set`) on `app_launched` and `daily_checkin`:
`version`, `build.config`, `macos`, `menu_bar.shown`, `menu_bar.chips`
(built-in chips `+`-joined, `scoped` for any per-model chip, `hidden`),
`menu_bar.icon_style`, `menu_bar.icon_driver` (window kind),
`toggles.crash_reports`, `toggles.performance`, `toggles.usage_data`; on
`daily_checkin` also `accounts.count`, `accounts.plans`, `install.age_days`,
`env.model`, `env.model_name`; on `widget_inventory` `widgets.count`,
`widgets.kinds`, `widgets.families`. `$set_once`: `install.first_seen`.

**Events** (all fire on a user action or once a day; nothing per scan cycle,
frame or forecast):

| Event | Where | Properties |
| --- | --- | --- |
| `app_launched` | `applicationDidFinishLaunching` | `origin`: `login_item`, `manual`, `after_update`, `other` |
| `app_quit` | terminate path | `uptime_minutes` |
| `update_installed` | first launch on a new version | `from_version`, `to_version` (digits and dots only) |
| `dashboard_opened` | dashboard window becomes visible | `trigger`: `menu`, `hotkey`, `notification`, `settings`, `widget`, `launch`, `dock`, `other` |
| `dashboard_closed` | window closed or hidden by the hotkey | `open_seconds` (coarse) |
| `tab_viewed` | on leaving a tab, or closing on it | `tab` (`dashboard`, `history`, `projects`, `models`, `settings`), `dwell_seconds` |
| `detail_opened` | modal root set or pushed; each sheet/popover appears | `which`: `day`, `project`, `session`, `projection` (prediction details / compare models), `alias_manager`, `alias_editor`, `collections_manager`, `collection_editor`, `bulk_merge`, `chart_share`; `pushed` |
| `control_changed` | card controls (`AnalyticsSettings` watch list, plus the project budget toggle) | `card`, `control`, `value`: History/Models/Projects `range` (`7d`…`all`), Models `grouping`, heatmap `metric`, table `sort` columns, toolbar `account_scope` (`all` / `one`, never the id), `project_budget` `enabled` |
| `export_used` | after a successful export | `flavor`: `daily_totals_csv`, `daily_by_model_csv`, `project_totals_csv`, `chart_image_copy`, `chart_image_save`, `chart_image_share` |
| `report_problem_opened` | Report a Problem window | `from`: `help_menu`, `status_menu`, `settings` |
| `setting_changed` | `AnalyticsSettings` watch list | `setting`; `value` only for bools and fixed sets (icon style, alert source, cost mode, time range, chips summary, icon driver as window kind); thresholds, ports, hours send the key alone; tokens, hosts and paths are not watched |
| `menubar_opened` | `menuWillOpen` | — |
| `menubar_item_clicked` | status menu items | `item`: `open_pacer`, `settings`, `report_problem`, `quit` |
| `menubar_context_action` | defined, not fired: the status item has no right-click menu today | `item` |
| `widget_inventory` | daily check-in, `WidgetCenter.getCurrentConfigurations` | `widgets`: list of {`kind`, `family`, `primary_window` / `secondary_window` (window kind or `default`), `range`, `pinned_project` (bool)}; `count`; `refreshes.<Kind>` (yesterday's granted timelines, `WidgetRefreshLog`) |
| `widget_tapped` | app opened by `pacer://widget?kind=&family=` (widgets carry `widgetURL`) | `kind`, `family` |
| `cli_command` | daily check-in, from `CLIRunLog`, timestamp = when it ran | `subcommand`, `flags` (names only), `outcome` (`ok`, `failure`, `misconfigured`, `hung`, `other`), `exit_code` (other only), `duration_bucket`, `source` (`api`/`offline`/`none`), `sample_weight`; at most 100 a day, evenly thinned |
| `shortcut_run` | each App Intent's `perform` | `intent` (struct name, allow-listed) |
| `api_request` | daily, tallied per route and client | `endpoint` (allow-listed route), `client` (family from User-Agent: `curl`, `python`, `prometheus`, …; the header is never sent), `count` |
| `notification_shown` | after a banner is posted | `kind` (`threshold`, `reset`, `burn_rate`, `global_reset`, `daily_cost`, `project_budget`, `custom_rule`, `daily_summary`, `test`), `window` (kind) |
| `notification_action` | notification response | `action`: `mute`, `open`, `click`, `dismiss`; `window` |
| `daily_checkin` | daily check-in | every field the Sentry `checkin.snapshot` carried until 2026-11 (settings, clients, accounts and plans, usage bands, lifecycle, environment, install, widgets, models present, `counter.*`) |

**Doors.** PacerCore code calls `Analytics.capture` (no-op until the app
installs `PostHogAnalyticsSink`). The widget and the CLI never link PostHog:
the widget's taps arrive as URLs and its refreshes through `WidgetRefreshLog`;
the CLI's runs through `CLIRunLog` (start lines carry flag names,
`CLIRunLog.flagNames`, known names only).


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
| 5,000 errors | crashes (rare) + hang/diagnostic reports | per-Mac daily send caps ("Send caps" below) in `beforeSend`; over-quota is dropped, never billed |
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

## Send caps

The Sentry DSN is public (it ships in the binary), and the free plan has no
server-side per-key rate limit (that is Business-only). Any one install, or
anyone who copies the DSN out of the app, could burn the month's quota; the
scarce one is errors (~5k a month). A Debug build on the maintainer's Mac sent
~14,000 `main_thread.stall_ms` metrics in a week. So the app limits itself.
This bounds what an honest Mac can send; it cannot stop someone replaying the
DSN by hand (that needs Sentry's inbound filters or a relay).

Per Mac, per UTC day (`TelemetryBudget`, PacerCore; constants in
`TelemetryBudget.Limits`):

| Kind | Release | Debug |
| --- | --- | --- |
| error events (excluding crashes) | 25 | 10 |
| app hangs | 10 | 3 |
| crashes (fatal, incl. forwarded widget/CLI crash reports) | 10 | 5 |
| MetricKit diagnostics | 10 | 10 |
| user feedback | 5 | 5 |
| transactions/spans (by root transaction) | 150 | 40 |
| metrics, per metric name | 300 | 60 |
| `main_thread.stall_ms` specifically | 100 | 20 |

Slow-scan traces keep their own, tighter 20 a day inside the transaction cap.
Debug is `#if DEBUG` (`build.config` debug).

- **Where applied**: `beforeSend` (errors, hangs, crashes, MetricKit; returns
  nil over budget), `tracesSampler` (root transactions; over budget samples at
  0), `beforeSendMetric` (per name; stall has its own), the Report a Problem
  sheet (offers the GitHub issue instead), the CLI's `pacer feedback` POST, and
  `CrashReportForwardingService` (widget/CLI crash envelopes; these bypass the
  SDK's hooks, so they spend the crash budget directly).
- **State**: App Group defaults, one dictionary (UTC day + counts), so a
  relaunch loop cannot reset it. Checks are in memory; rare kinds persist at
  once, metrics and transactions at most every 10 s and on quit.
- **Counted**: each drop adds `telemetry.capped.<kind>` (and
  `telemetry.capped.metric.<name>`) to `TelemetryCounters`, so the next daily
  check-in shows capping.
- **Never capped**: the daily check-in (`pacer.checkin` transaction,
  `checkin.*` metrics). Its counter metrics are one per name per day, far under
  any cap.
- **Known gap**: the CLI and the app write the same defaults key without a
  lock, so a feedback sent by the CLI at the instant the app persists can lose
  one count. Harmless at five a day.

## Toggle mapping (first release; superseded by "Two toggles")

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
  the hang, which our run-loop watchdog cannot). `enableMetricKit = true`. Both capped per Mac per
  day in `beforeSend` (see "Send caps"). Idle-CPU cost of Sentry's watchdog thread measured before
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

## Update 2026-11-02: answers and the full metrics plan

Answers: `pacer feedback` sends to Sentry by default; the CLI counts its commands; Help → "Report a
Problem…" yes; check-in settings list kept. Eric also wants crashes, hangs and slow runs from the
CLI and widget, not just the app. Still a plan: nothing is built.

### Covering the CLI and the widget without Sentry inside them

- Neither runs the Sentry SDK. The widget has no network and a ~30 MB budget; sharing the SDK's
  cache folder with the app is unsupported (no cross-process lock, crash reports are per bundle).
  The CLI is run constantly by agents and must stay fast.
- **Crashes**: macOS writes a crash report (`.ips`) for every crashing process. The app (not
  sandboxed) scans `~/Library/Logs/DiagnosticReports` for `pacer-*` and `PacerWidgets-*` reports
  once a day and at launch, and forwards each new one to Sentry with its binary images
  (`debug_meta`), so it is symbolicated against the uploaded dSYMs like an app crash. Sentry
  documents an `event.applecrashreport` attachment for exactly this; whether it accepts the JSON
  `.ips` form or needs the text form is the first thing to test. Fallback: build the native event
  ourselves (image UUID + base + frame offsets are all in the `.ips`).
- **Hangs and slow runs**: both processes time their own work and append one line per run to a
  file in the App Group container (the `WidgetRefreshLog` pattern: `O_APPEND`, small lines, safe
  with many concurrent `pacer` processes, no defaults read-modify-write). The CLI writes subcommand,
  exit code, duration, API-or-offline; never arguments, accounts or paths. The widget adds the
  timeline build time to its existing refresh log line. The app rolls both up daily into the
  check-in and sends per-subcommand duration distributions; runs over a threshold (CLI > 5 s
  excluding `wait`; widget timeline > 1 s) also go as individual slow-run metrics.
- **CLI freezes**: a stuck `pacer` shows as a run that started but never wrote its end line. The
  CLI writes a start line too; the app counts starts with no end older than 10 minutes (excluding
  `wait`, whose own max-wait is known) as hung runs.
- **App crash that Sentry missed** (e.g. killed by the system): the same `.ips` scan catches
  `Pacer-*` reports Sentry did not already send, deduplicated by crash time.

### Metrics catalog

All under "Share usage data" unless marked (crash). Attributes in brackets; none identify a
person, account, project or path. Account ids are org ids, so never sent; plan tier is used.

1. **Model downloads** (`ArenaWeightStore`, `:325` and `:252`): per download, a span with model,
   bytes, seconds, attempts, resumed; failures counted by error code. Daily: which models are
   present on disk. [model]
2. **Fitting and grading** (no gradient training exists; these are curve fits, rankings and model
   inference): engine refit duration and per-phase breakdown (`recompute` already times phases),
   daily spend-to-meter fit duration and fitted/skipped counts, arena scorer pass time, CPU used,
   and slowest model per pass. [phase, model, window kind]
3. **Upgrades and backfills**: first launch after an update is detectable (last-seen build in
   `WidgetExtensionRelauncher`). One span for the whole post-update rebuild: full re-read, cost
   rebuild, price repricing and rollup bootstraps, with the phase steps `HistoryRebuildStatus`
   already names, entries and files processed, and the record backfill. Plus SwiftData
   index-repair time. [from-version, to-version, what rebuilt]
4. **Forecast accuracy**: once a day per window kind, the model each account picked, its typical
   error (percentage points), the gap to the best model, how many models were ranked, cycles of
   history, and which models were well behind. Per account but labelled only by plan tier and an
   account number local to that Mac (1, 2, 3…). [model, window kind, plan tier]
5. **Accounts and plans**: number of accounts, count per plan tier (raw tier string, stable across
   the Max/Ultra renaming), Claude Desktop, cswap and pinned-profile counts. [tier]
6. **Usage levels** (a new kind of data: see question 1): per window kind, yesterday's peak
   percentage in 10-point bands, whether any window hit 100 % or was forecast to, number of models
   used, and token volume as an order-of-magnitude band. No costs, no exact tokens.
7. **What people use**: dashboard tab views and time on tab, detail sheets opened (kind only),
   menu-bar menu opens and which item, dashboard window opens, settings changed (key name, not
   value, except for the check-in list), notification Mute/Open clicks, Shortcuts actions run,
   local API routes hit, CLI subcommands, installed widgets (kind + size). The least-used shows
   up as zero counts against the full list, which the check-in carries.
8. **Slow operations**: scan cycles > 1 s with phase breakdown (already planned), OAuth poll
   latency and outcome (ok / 401 / 429 / network), pricing refresh time, local API snapshot build
   time, widget timeline time, CLI command time, main-thread stalls (the watchdog's threshold is
   100 ms in code; send ≥ 250 ms), launch-to-ready time, memory footprint at launch, hourly and
   after a rebuild.
8a. **Check-in core and build/arena tags** (2026-11): the check-in snapshot (a metric, all
   attributes) is also sent as the `pacer.checkin` transaction with a small core, because
   `count_unique(user.id)` works on spans and not metrics. Core: `checkin.day`, `env.macos`,
   `env.model`, `env.model_name` (readable Mac model from `hw.model`, raw identifier when unknown),
   `settings.cost_mode`, `accounts.count`, `accounts.plans` (distinct plan tiers, sorted, joined
   with `+`, `default_claude_` dropped; `none` without accounts), `usage.seven_day.peak_band` and
   `usage.five_hour.peak_band` (the latter only where a 5-hour window exists), `install.first_seen`
   (day only; first launch, or backfilled once from the oldest account row), `install.age_days`
   and `build.config` (`debug`/`release`). Scope tags on every crash, hang and MetricKit report:
   `build.config` and `arena.cpu_mode` (`full` while plugged in and idle, `fifth` otherwise).
   `arena.pass_seconds` / `arena.cpu_seconds` are sent only for passes that graded something
   (they were always 0 because no-op incremental passes were reported too).
9. **Crash-side** (crash toggle): app crashes, hangs and MetricKit as planned, plus forwarded CLI
   and widget crashes and hung CLI runs.

Hot paths kept off: no per-click events (aggregate the click probe, send distributions), no
per-cycle or per-forecast events, `ProcessMemory` only hourly.

### PostHog

Still Sentry. Every item above is a count, duration or distribution sliced by version, model,
plan tier, window or install, which Sentry metrics and traces handle with group-by and dashboards.
PostHog adds value for exploring by hand: drilling into one install's history, SQL, funnels and
retention curves, and a world map. Revisit after seeing the Sentry dashboards; if added, it would
take only the usage events (items 5–7) and Sentry keeps crashes, hangs and performance.

### Found along the way

- Every install tries to download all four large forecast networks (~2.7 GB), including models it
  never picks. Worth an issue on its own, independent of telemetry.
- `CLI` and widget crashes have never been visible to anyone but the user.

### Update 2026-11-02 (2): answers, the download question, more signals

Answers: usage levels yes (banded); forecast accuracy reported per account AND per Mac.

**The 2.7 GB download is by design, not a bug.** `ArenaRuntime.start` collects the weights of
every selectable model (`roster.selectable` → `requiredWeights`) and fetches what's missing before
each scorer pass, because a Mac can only pick its best model by grading every candidate on its own
history. The cost: ~2.7 GB of disk and bandwidth per install (Timestral-123M 490 MB, -209M 837 MB,
Chronos 478 MB, TimesFM 925 MB), in `~/Library/Application Support/Pacer/ForecastWeights`, with
nothing in the UI saying so. Already skips expensive/constrained networks. Telemetry item 4
(which models win, per plan and window, across Macs) answers whether the big ones ever win;
if they rarely do, download them only when cheaper models leave room to improve.

**More signals for maintaining the app** (added to the catalog):

10. **Data health** (the bug classes that have bitten before): malformed lines skipped, models
    with no price (the silent-$0 class), streamed-message supersedes, cursor resets, archive
    integrity results, rollup gaps rebuilt, dedup repairs. Counts per day, alert on spikes.
11. **Format drift from Anthropic**: Claude Code versions seen in transcripts, unknown usage
    fields, new model ids before pricing knows them, usage-endpoint shape changes (new `limits[]`
    kinds, a window that disappears, as `five_hour` did for Ultra). Alerts on first sighting.
12. **Credentials and polling health**: keychain read failures, 401/429 rates, Desktop and cswap
    credential errors, poll lanes stalled.
13. **Environment**: macOS, Mac model and architecture, RAM, free disk, store size and row
    counts, archive size, transcript file count, both config dirs present, `CLAUDE_CONFIG_DIR`
    set, time-zone offset (day-boundary bugs).
14. **Lifecycle**: launched at login or by hand, uptime, restarts per day, unclean exits, Sparkle
    check/install failures, time from a release to each Mac running it.
15. **Energy**: process CPU seconds per hour and while idle (the 0 % idle invariant, fleet-wide).
16. **Feature errors**: notification permission state, API server port in use, skill install
    failures, widget timeline failures.
17. **Problem reports carry a diagnostics snapshot**: version, settings, store stats and the last
    lines of tag-allow-listed, scrubbed log, shown in the sheet before sending.
18. **Remote switch**: a small JSON beside the appcast (Pacer already fetches price history from
    there) that can lower sample rates or turn a signal off without a release.
19. **Sentry alerts**: new issue, regression, crash-free below a floor, new format-drift sighting,
    data-health spike, idle CPU above a floor.

### Crash-report forwarding test (2026-11-02): route A

A throwaway CLI crashed with `fatalError`; macOS wrote `pacertest-crashy-….ips` (JSON header line
+ JSON body: `usedImages` with uuid/base/size, `threads[faultingThread].frames` with
imageIndex/imageOffset/symbol, `exception` type/signal). Sent two ways:
- **A, hand-built native event** (frames `instruction_addr = base + imageOffset`, oldest first;
  `debug_meta.images` macho uuid/base/size): landed as PACER-3 after ~4 min, system frames
  symbolicated (`_assertionFailure`, `start`), app frames unknown only because no dSYM was
  uploaded. **This is the route.** Also copy the `.ips` frame `symbol` into `function` when present,
  so frames read even before dSYMs.
- **B, `event.applecrashreport` attachment with the JSON `.ips`**: accepted (PACER-2) but not
  parsed: no stack. Ruled out.
- The `fatalError` message is not in the `.ips`; the forwarded event says the signal and where.

### Release-note bullet (for the release that first ships this)

**Crash reports and usage stats.** Pacer now sends crash reports and anonymous
usage stats to Sentry so bugs and slowdowns get found. Turn either off in
Settings → Privacy.
