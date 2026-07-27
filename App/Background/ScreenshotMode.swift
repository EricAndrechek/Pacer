import AppKit
import SwiftUI
import SwiftData
import WidgetKit
import PacerCore
import PacerUI

/// Headless marketing-screenshot generator.
///
/// When the app is launched with `PACER_SCREENSHOT_MODE=1`, the normal
/// startup is replaced with a self-contained capture run:
///
///   1. `PacerAppDelegate` swaps the on-disk App Group container for an
///      **in-memory** one (`PacerStore.makeInMemoryContainer`) and skips
///      the single-instance gate, stderr redirect, menu-bar item, and the
///      background scan/OAuth service. Nothing reads or mutates the
///      user's real `~/.claude` data or the real `pacer.sqlite`.
///   2. `seed(into:)` fills that container with deterministic synthetic
///      usage — a healthy-looking heavy Claude Code user — so every card
///      renders populated.
///   3. `captureAll(container:)` hosts the **real** app views off-screen
///      (so SwiftUI's lifecycle runs and `@State` caches / Charts
///      populate, which a one-shot `ImageRenderer` pass can't do), draws
///      each into a PNG, and writes it to `PACER_SCREENSHOT_DIR`.
///   4. The process exits.
///
/// The off-screen window is ordered in but positioned far outside any
/// screen and the app never activates, so running this steals no focus
/// and can happen while a real Pacer is open and while the user keeps
/// working.
///
/// Drive it with `make screenshots`. Re-run it after any meaningful UI
/// change so the README images don't drift from the real app.
@MainActor
enum ScreenshotMode {
    /// Engine warmed over the seeded in-memory store, injected into every
    /// captured scene so engine-powered cards render real answers.
    @MainActor private static var screenshotEngine: UsageIntelligenceEngine?

    /// True when launched for a screenshot run.
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["PACER_SCREENSHOT_MODE"] == "1"
    }

    /// Output directory for the PNGs. `PACER_SCREENSHOT_DIR` (the make
    /// target passes an absolute path) or `./screenshots` relative to
    /// the launch CWD as a fallback.
    static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["PACER_SCREENSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    // MARK: - Capture driver

    /// Render every scene and write the PNGs, then return. The caller
    /// (`applicationDidFinishLaunching`) exits the process afterward.
    static func captureAll(container: ModelContainer) async {
        let outDir = outputDirectory
        try? FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true
        )
        log("writing screenshots to \(outDir.path)")

        // Focused proof run for the pace-card layout work: render only the
        // `pace-layout-*` scenes (each over its own tiny seeded container) and
        // return, so `docs/mockups` gets just those without the README scenes.
        if ProcessInfo.processInfo.environment["PACER_SCREENSHOT_LAYOUT_ONLY"] == "1" {
            await captureLayoutScenes()
            log("layout screenshots complete")
            return
        }

        // Focused proof run for the scoped-alerts work: render just the
        // Rate-limit alerts settings card (5h + 7d + a couple scoped per-model
        // windows + a dormant one) into docs/mockups and return. Run with
        // PACER_SCREENSHOT_ALERTS_ONLY=1 and PACER_SCREENSHOT_DIR pointed there.
        if ProcessInfo.processInfo.environment["PACER_SCREENSHOT_ALERTS_ONLY"] == "1" {
            await captureScopedAlertsScenes()
            log("scoped-alerts screenshots complete")
            return
        }

        // Warm an intelligence engine over the seeded in-memory store so the
        // engine-powered cards (intelligence card, projected EOD/month tiles,
        // burn rows) render real answers instead of their warming-up states.
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.recompute(now: Date())
        screenshotEngine = engine

        // Order out any stray scene window SwiftUI may have created so
        // nothing flashes on screen. We capture our own hosting views
        // directly, so other windows are irrelevant to the output.
        for window in NSApp.windows { window.orderOut(nil) }

        // A richer menu-bar readout for the status-bar shot than the
        // default (icon + 5-hour %).
        PacerSettings.store.set(
            "icon,five_hour_pct,seven_day_pct,today_cost",
            forKey: PacerSettings.Key.menuBarChips
        )

        // Window scenes — framed like a real macOS window screenshot:
        // traffic-light titlebar, rounded corners, a soft drop shadow on
        // a transparent margin.
        await capture("dashboard", width: 1280, height: 860, scheme: .light,
                      card: true, chrome: true, title: "Dashboard", container: container) { ContentView() }
        await capture("dashboard-dark", width: 1280, height: 860, scheme: .dark,
                      card: true, chrome: true, title: "Dashboard", container: container) { ContentView() }
        await capture("history", width: 1180, height: 840, scheme: .light,
                      card: true, chrome: true, title: "History", container: container) { HistoryView() }
        await capture("models", width: 1180, height: 900, scheme: .light,
                      card: true, chrome: true, title: "Models", container: container) { ModelsView() }

        // The menu-bar experience as one cohesive image: a slice of the
        // macOS menu bar with Pacer's readout, and the click-down popover
        // hanging beneath it. Self-decorated on a transparent canvas.
        await capture("menubar", width: nil, height: nil, scheme: .light,
                      card: false, container: container) { MenuBarExperience() }
        await capture("menubar-dark", width: nil, height: nil, scheme: .dark,
                      card: false, container: container) { MenuBarExperience() }

        // The home-screen widget family.
        await capture("widgets", width: nil, height: nil, scheme: .light,
                      card: false, container: container) { WidgetGallery() }

        // Scoped windows as first-class pace items — the dashboard pace card
        // with 5h + 7d + several per-model windows in the responsive N-column
        // grid (light + dark), and the large widget families showing the same
        // set. Captured for docs/mockups (run with PACER_SCREENSHOT_DIR pointed
        // there); design polish pending sign-off.
        await capture("scoped-firstclass-dashboard", width: 1180, height: nil, scheme: .light,
                      card: true, container: container) { PaceChartCard() }
        await capture("scoped-firstclass-dashboard-dark", width: 1180, height: nil, scheme: .dark,
                      card: true, container: container) { PaceChartCard() }
        await capture("scoped-firstclass-widget", width: nil, height: nil, scheme: .light,
                      card: false, container: container) { ScopedFirstClassWidgetGallery() }

        // Projects ▸ Collections — the manager, the editor, and the
        // integrated Projects tab. Synthetic collections over synthetic
        // project rollups (see `seedCollections`).
        await capture("collections-manager", width: nil, height: nil, scheme: .light,
                      card: true, container: container) {
            CollectionsManager()
        }
        await capture("collections-editor", width: nil, height: nil, scheme: .light,
                      card: true, container: container) {
            CollectionEditorShowcase()
        }
        // The integrated Projects tab: collection filter bar + per-row
        // membership chips (the "not a separate tab" model).
        await capture("projects-collections", width: 1060, height: 900, scheme: .light,
                      card: true, chrome: true, title: "Projects", container: container) {
            ProjectsView()
        }
        // Scoped into a nested collection — shows the composition breakdown.
        await capture("projects-collections-scoped", width: 1060, height: 940, scheme: .light,
                      card: true, chrome: true, title: "Projects", container: container) {
            ProjectsView(initialScope: "client")
        }

        // The share-image export — the exact ImageRenderer output the
        // in-app "Share…" action produces, for the README's share showcase.
        captureShareCard(container: container)

        log("screenshots complete")
    }

    /// Render the branded 7-day pace share card the same way the in-app
    /// share action does (`App/Share`), from the seeded rate-limit trail,
    /// in light + dark. Documents the share feature and stays in sync via
    /// `make screenshots`. Unlike the window scenes, this needs no
    /// off-screen hosting: the card takes inline data, so a one-shot
    /// `ImageRenderer` pass (what the real export uses) is faithful.
    private static func captureShareCard(container: ModelContainer) {
        let ctx = ModelContext(container)
        let duration: TimeInterval = 7 * 86_400
        let descriptor = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.window == "seven_day" },
            sortBy: [SortDescriptor(\.sampledAt)]
        )
        guard let samples = try? ctx.fetch(descriptor),
              let latest = samples.last, let resets = latest.resetsAt else {
            log("⚠️ share-card: no seven_day samples"); return
        }
        let cycleStart = resets.addingTimeInterval(-duration)
        let now = Date()
        var points = samples
            .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .map { PaceChartView.Data.Point(time: $0.sampledAt, value: $0.usedPercentage) }
        let tailTime = min(now, resets)
        if points.last?.time != tailTime {
            points.append(.init(time: tailTime, value: latest.usedPercentage))
        }
        let data = PaceChartView.Data(
            cycleStart: cycleStart, resetsAt: resets,
            durationSeconds: duration, points: points, usedPct: latest.usedPercentage
        )
        let cycle = DisplayCycle.resolve(resetsAt: resets, duration: duration, now: now)
        let payload = PaceSharePayload(
            title: "7-Day Usage Pace", data: data, duration: duration, resetsAt: resets,
            usedPct: latest.usedPercentage, paceEndPct: cycle.paceFraction * 100,
            fileName: "pacer-7-day-pace.png"
        )
        // Transparent margin + soft drop shadow so it drops into the README
        // alongside the window-chrome scenes (same treatment as `card:`).
        for scheme in [ColorScheme.light, .dark] {
            let framed = PaceShareCard(payload: payload, scheme: scheme)
                .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.18), radius: 22, x: 0, y: 12)
                .padding(40)
            let name = scheme == .dark ? "share-card-dark" : "share-card"
            if let png = ChartImageRenderer.pngData(for: framed, scale: 2) {
                try? png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
                log("✓ \(name).png (\(png.count) bytes)")
            } else {
                log("⚠️ share-card: render failed for \(name)")
            }
        }
    }

    // MARK: - Scoped-alerts proof scene

    /// Render the Rate-limit alerts settings card with the fixed 5h/7d windows
    /// plus a couple of scoped per-model windows (one configured, one dormant),
    /// in light + dark. Seeds a fresh in-memory container (scoped
    /// `UsageLimitSample` rows + `AlertRule` threshold rows) and temporarily
    /// sets the notification prefs on the shared store, restoring them after so
    /// the run never mutates the user's real settings.
    private static func captureScopedAlertsScenes() async {
        guard let container = try? PacerStore.makeInMemoryContainer() else {
            log("⚠️ scoped-alerts: container creation failed"); return
        }
        let ctx = ModelContext(container)
        let now = Date()
        // Scoped windows (Haiku/Opus/Fable/Sonnet weekly) as first-class rows.
        seedUsageLimits(ctx, now: now)
        // Configured scoped alerts: Haiku 80% + 95%, Fable 75%, plus a dormant
        // "Cowork" window (has a rule but no live sample ⇒ paused).
        let scopedRules: [(id: String, name: String, pcts: [Double])] = [
            ("weekly_scoped|Haiku|",  "Haiku",  [80, 95]),
            ("weekly_scoped|Fable|",  "Fable",  [75]),
            ("weekly_scoped|Cowork|", "Cowork", [85]),   // dormant (not in poll)
        ]
        for r in scopedRules {
            for pct in r.pcts {
                ctx.insert(AlertRule(name: r.name, metric: AlertRuleMetric.rateLimitPct,
                                     thresholdValue: pct, scopedWindow: r.id))
            }
        }
        do { try ctx.save() } catch { log("⚠️ scoped-alerts: seed save failed: \(error)") }

        // Temporarily present a healthy notification config on the shared store.
        let store = PacerSettings.store
        let saved: [String: Any?] = [
            PacerSettings.Key.notificationsEnabled: store.object(forKey: PacerSettings.Key.notificationsEnabled),
            PacerSettings.Key.fiveHourThresholdsCSV: store.object(forKey: PacerSettings.Key.fiveHourThresholdsCSV),
            PacerSettings.Key.sevenDayThresholdsCSV: store.object(forKey: PacerSettings.Key.sevenDayThresholdsCSV),
        ]
        store.set(true, forKey: PacerSettings.Key.notificationsEnabled)
        store.set("75", forKey: PacerSettings.Key.fiveHourThresholdsCSV)
        store.set("50,80", forKey: PacerSettings.Key.sevenDayThresholdsCSV)

        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "scoped-alerts-dark" : "scoped-alerts"
            await capture(name, width: 620, height: nil, scheme: scheme,
                          card: true, container: container) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("NOTIFICATIONS")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    RateLimitAlertsCard()
                }
                .padding(20)
            }
        }

        // Restore the user's real prefs.
        for (key, value) in saved {
            if let value { store.set(value, forKey: key) }
            else { store.removeObject(forKey: key) }
        }
    }

    // MARK: - Pace-layout proof scenes

    /// One scoped window to seed for a layout scene.
    private struct LayoutScoped {
        let model: String
        let group: String     // "session" / "weekly" (drives the ordering side)
        let pct: Double
        let active: Bool
        let severity: String
    }

    /// Render the `pace-layout-*` proof captures for the pace-card layout work:
    /// the two-window (unchanged 5h/7d) case, the session-vs-weekly sort with
    /// the heroes glued in the middle, the 4/5/6-window balancing (2+2 / 3+2 /
    /// 3+3 at a width that fits three across), and a narrow-width capture that
    /// drops to two columns (2+2+2). Each scene seeds its own tiny in-memory
    /// container so the window count is controlled independent of the shared
    /// marketing seed. Widths are chosen against the card's 20pt padding so the
    /// grid's content width lands three-across at 940 and two-across at 640.
    private static func captureLayoutScenes() async {
        // Weekly-only ladders for the balance proofs (hottest first, one active
        // + elevated to exercise the dot + severity chip).
        let w4: [LayoutScoped] = [
            .init(model: "Haiku", group: "weekly", pct: 93, active: true,  severity: "warning"),
            .init(model: "Opus",  group: "weekly", pct: 84, active: false, severity: "normal"),
        ]
        let w5 = w4 + [.init(model: "Fable",  group: "weekly", pct: 49, active: false, severity: "normal")]
        let w6 = w5 + [.init(model: "Sonnet", group: "weekly", pct: 22, active: false, severity: "normal")]

        // (a) exactly 5h + 7d — the unchanged two-column HStack.
        await captureLayoutScene("pace-layout-2-fixed", width: 940, scoped: [])
        // (b) sort: one session-scoped + one weekly-scoped ⇒ [Fable, 5h, 7d, Opus].
        await captureLayoutScene("pace-layout-sort", width: 940, scoped: [
            .init(model: "Fable", group: "session", pct: 44, active: false, severity: "normal"),
            .init(model: "Opus",  group: "weekly",  pct: 68, active: true,  severity: "warning"),
        ])
        // (c) balance at a width that fits three across: 4→2+2, 5→3+2, 6→3+3.
        await captureLayoutScene("pace-layout-4", width: 940, scoped: w4)
        await captureLayoutScene("pace-layout-5", width: 940, scoped: w5)
        await captureLayoutScene("pace-layout-6", width: 940, scoped: w6)
        // (d) narrow width — same six windows drop to two columns (2+2+2).
        await captureLayoutScene("pace-layout-narrow", width: 640, scoped: w6)
    }

    /// Seed a fresh in-memory container with the fixed 5h/7d trail plus the
    /// given scoped windows, warm an engine over it, and capture `PaceChartCard`
    /// at `width`. Swaps `screenshotEngine` to this scene's engine for the
    /// capture so the columns forecast against their own data.
    private static func captureLayoutScene(_ name: String, width: CGFloat, scoped: [LayoutScoped]) async {
        guard let container = try? PacerStore.makeInMemoryContainer() else {
            log("⚠️ \(name): container creation failed"); return
        }
        let ctx = ModelContext(container)
        let now = Date()
        seedRateLimits(ctx, now: now)
        seedLayoutScoped(ctx, now: now, scoped: scoped)
        do { try ctx.save() } catch { log("⚠️ \(name): seed save failed: \(error)") }

        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.recompute(now: now)
        let previous = screenshotEngine
        screenshotEngine = engine
        await capture(name, width: width, height: nil, scheme: .light,
                      card: true, container: container) { PaceChartCard() }
        screenshotEngine = previous
    }

    /// Seed a full current-cycle history (a monotone concave climb to `pct`)
    /// for each scoped window, plus a `now`-anchored latest-batch row, mirroring
    /// `seedUsageLimits` but for an arbitrary session/weekly set.
    private static func seedLayoutScoped(_ ctx: ModelContext, now: Date, scoped: [LayoutScoped]) {
        for (idx, s) in scoped.enumerated() {
            // Fully qualified: a private `ScreenshotMode.WindowSpec` shadows the
            // PacerCore type inside this file.
            let duration = PacerCore.WindowSpec.scopedDuration(group: s.group)
            // Reset offsets: session +2h19m (8_340s), weekly +2d4h (187_200s).
            let isSession = s.group.lowercased() == "session"
            let resetOffset: TimeInterval = isSession ? 8_340 : 187_200
            let reset = now.addingTimeInterval(resetOffset)
            let kind = "\(s.group)_scoped"
            let identity = "\(kind)|\(s.model)|"
            let cycleStart = reset.addingTimeInterval(-duration)
            let elapsed = max(1, now.timeIntervalSince(cycleStart))
            let interval = duration / 60
            func insert(at t: Date, pct: Double) {
                ctx.insert(UsageLimitSample(
                    sampledAt: t, identity: identity, kind: kind, group: s.group,
                    label: s.model, percent: pct, resetsAt: reset,
                    severity: s.severity, isActive: s.active,
                    modelId: nil, modelDisplayName: s.model, surface: nil, source: "oauth"))
            }
            var t = cycleStart
            var i = 0
            var last = 0.0
            while t < now {
                let frac = max(0, min(1, t.timeIntervalSince(cycleStart) / elapsed))
                var pct = s.pct * (frac * (1.08 - 0.08 * frac))
                if frac > 0.02, frac < 0.98 { pct += noise(i &* 13 &+ idx &* 7) * 1.2 }
                pct = max(last, min(s.pct, pct))
                last = pct
                insert(at: t, pct: pct)
                t = t.addingTimeInterval(interval)
                i += 1
            }
            insert(at: now, pct: s.pct)
        }
    }

    /// Host `content` in an off-screen window, let the SwiftUI lifecycle
    /// run, then snapshot it to a PNG with transparency preserved.
    ///
    /// `card: true` frames the content like a macOS window screenshot —
    /// an opaque window-colored backing (which is also what keeps
    /// dark-mode white text from ghosting against a transparent backing),
    /// rounded corners, a hairline border, and a drop shadow on a
    /// transparent margin. `card: false` renders the content as-is on a
    /// transparent canvas (for views that decorate themselves, like the
    /// widget gallery and the status-bar readout).
    ///
    /// `nil` for `width`/`height` means "size to the content's intrinsic
    /// dimension" (measured via `fittingSize`).
    private static func capture(
        _ name: String,
        width: CGFloat?,
        height: CGFloat?,
        scheme: ColorScheme,
        card: Bool,
        cornerRadius: CGFloat = 14,
        chrome: Bool = false,
        title: String = "",
        container: ModelContainer,
        @ViewBuilder _ content: () -> some View
    ) async {
        let margin: CGFloat = card ? 56 : 28
        let inner = content()
            .modelContainer(container)
            .environment(\.usageEngine, screenshotEngine)
            .frame(width: width, height: height)

        // Optional macOS window chrome — a titlebar with traffic-light
        // buttons above the content, so window scenes read like a real
        // app-window screenshot.
        let framed: AnyView = chrome
            ? AnyView(VStack(spacing: 0) { MacWindowChrome(title: title); inner })
            : AnyView(inner)

        let decorated: AnyView
        if card {
            decorated = AnyView(
                framed
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 12)
            )
        } else {
            decorated = framed
        }
        let root = AnyView(decorated.padding(margin).preferredColorScheme(scheme))

        // Always size from the SwiftUI ideal size — accounts for the
        // titlebar and any intrinsic (nil) dimension without per-scene math.
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 5000, height: 5000)
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let finalSize = CGSize(width: ceil(fit.width), height: ceil(fit.height))
        await snapshot(hosting, size: finalSize, name: name, scheme: scheme)
    }

    /// Realize `hosting` in an off-screen, never-activated, non-opaque
    /// window (so transparency is preserved), let the SwiftUI lifecycle
    /// run, then write a PNG.
    private static func snapshot(
        _ hosting: NSHostingView<AnyView>, size: CGSize, name: String, scheme: ColorScheme
    ) async {
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -60_000, y: -60_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()

        // Spin the run loop so SwiftUI mounts, @Query fetches land, the
        // @State scan-tick caches refresh, and Charts lay out.
        await settle(seconds: 2.6)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        await settle(seconds: 1.0)

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            log("⚠️ could not allocate bitmap for \(name)")
            window.orderOut(nil)
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            log("⚠️ could not encode PNG for \(name)")
            window.orderOut(nil)
            return
        }
        do {
            try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
            log("✓ \(name).png (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } catch {
            log("⚠️ write failed for \(name): \(error)")
        }
        window.orderOut(nil)
    }

    /// Yield to the main run loop for `seconds` without blocking it, so
    /// SwiftUI updates and async fetches can make progress.
    private static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[Pacer screenshots] \(message)\n".utf8))
    }
}

// MARK: - Synthetic data

extension ScreenshotMode {
    // Model mix mirrors a real heavy Claude Code user: overwhelmingly
    // Opus, a little Sonnet, a sliver of Haiku.
    // "Today" / session / hourly surfaces use the current flagships.
    private static let opus = "claude-opus-4-8"
    private static let sonnet = "claude-sonnet-5"
    private static let haiku = "claude-haiku-4-5"

    /// A realistic multi-family, multi-version mix for the six-month daily
    /// rollups, so the Models tab (list, share donut, trend) and the
    /// dashboard's per-model card show the curated family/version colors and
    /// pretty names. Each model is "active" over a window of day-offsets from
    /// today (0 = today): newer Opus sub-versions arrive as older ones fade,
    /// Sonnet rolls 4-6 → 5, and Fable/Mythos appear as recent slivers.
    private struct SeedModel { let id: String; let weight: Double; let active: ClosedRange<Int> }
    private static let seedModels: [SeedModel] = [
        SeedModel(id: "claude-opus-4-6",   weight: 0.50, active: 62...150),
        SeedModel(id: "claude-opus-4-7",   weight: 0.80, active: 20...130),
        SeedModel(id: "claude-opus-4-8",   weight: 0.90, active: 0...40),
        SeedModel(id: "claude-sonnet-4-6", weight: 0.10, active: 6...182),
        SeedModel(id: "claude-sonnet-5",   weight: 0.16, active: 0...4),
        SeedModel(id: "claude-haiku-4-5",  weight: 0.05, active: 0...182),
        SeedModel(id: "claude-fable-5",    weight: 0.09, active: 0...30),
        SeedModel(id: "claude-mythos-5",   weight: 0.06, active: 0...16),
    ]

    /// Fill an (in-memory) container with deterministic, healthy-looking
    /// usage so every dashboard / history / menu-bar card renders
    /// populated. All dates are relative to "now" so the time-windowed
    /// `@Query` predicates (today, last 30 days, last six months) match.
    static func seed(into container: ModelContainer) {
        let ctx = ModelContext(container)
        let now = Date()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)

        seedDailyAggregates(ctx, startOfToday: startOfToday, cal: cal)
        seedPriorHourly(ctx, startOfToday: startOfToday, cal: cal)
        seedTodayHourly(ctx, today: TokenSample.formatDate(startOfToday), now: now, cal: cal)
        seedRateLimits(ctx, now: now)
        seedUsageLimits(ctx, now: now)
        seedSessions(ctx, now: now)
        seedRecentTokens(ctx, now: now)
        seedCollections(ctx, startOfToday: startOfToday, cal: cal)

        ctx.insert(ClaudeCodeMeta(
            key: ClaudeCodeMetaKey.lastIncrementalScanAt,
            value: iso8601(now)
        ))

        do {
            try ctx.save()
            log("seeded synthetic usage")
        } catch {
            log("⚠️ seed save failed: \(error)")
        }
    }

    /// Today's mid-day cost-so-far. Heavy-but-not-extreme, in the spirit
    /// of a real power user (whose days run higher still).
    private static let todayCost = 124.0

    /// Six months of per-model daily rollups, shaped from real heavy-user
    /// trends: weekday-driven with a Tue/Wed midweek peak and much quieter
    /// weekends, high day-to-day variance, the odd big spike day, and
    /// occasional gap days — so the heatmap and 30-day chart look lived-in.
    private static func seedDailyAggregates(
        _ ctx: ModelContext, startOfToday: Date, cal: Calendar
    ) {
        for d in 0..<182 {
            guard let day = cal.date(byAdding: .day, value: -d, to: startOfToday) else { continue }
            // ~12% gap days (no usage), but today always has data.
            if d != 0 && noise(d &* 7 &+ 5) < 0.12 { continue }

            let ds = TokenSample.formatDate(day)
            let weekday = cal.component(.weekday, from: day)   // 1=Sun … 7=Sat
            let isWeekend = (weekday == 1 || weekday == 7)
            let isMidweek = (weekday == 3 || weekday == 4)     // Tue/Wed peak
            let r = noise(d)
            let ramp = 0.85 + 0.3 * Double(182 - d) / 182.0    // slight recent uptick

            var dayCost = (isWeekend ? 30.0 : 110.0) * (0.55 + 0.9 * r) * ramp
            if isMidweek { dayCost *= 1.25 }
            // Occasional spike day (a long heads-down session).
            if !isWeekend && noise(d &* 13 &+ 1) > 0.94 { dayCost *= 3.0 }
            if d == 0 { dayCost = todayCost }

            // Spread the day's cost across the models active on this day,
            // by weight (Opus-dominant), with a little per-model jitter so
            // the trend has texture rather than flat bands.
            let active = seedModels.filter { $0.active.contains(d) }
            let totalW = active.reduce(0.0) { $0 + $1.weight }
            guard totalW > 0 else { continue }
            for m in active {
                let jitter = 0.8 + 0.4 * noise(d &* 17 &+ m.id.count)
                let cost = dayCost * (m.weight / totalW) * jitter
                if cost >= 0.05 { insertDaily(ctx, date: ds, model: m.id, cost: cost) }
            }
        }
    }

    /// Fake project rollups + a few collections so the Projects ▸
    /// Collections lane, tree, detail, and manager render populated. The
    /// leaf paths are absolute (tilde-expanded) so the folder rule matches
    /// them. Fictional placeholder names only. Demonstrates all three
    /// membership kinds plus overlap (firmware is in Acme Corp via rule
    /// AND Side Projects by hand) and nesting (the Globex client
    /// collection contains Acme Corp).
    private static func seedCollections(
        _ ctx: ModelContext, startOfToday: Date, cal: Calendar
    ) {
        let home = NSHomeDirectory()
        let workRoot = "\(home)/Code/work/acme-corp"
        // (path, per-day cost base)
        let leaves: [(String, Double)] = [
            ("\(workRoot)/api", 16),
            ("\(workRoot)/firmware", 9),
            ("\(workRoot)/web-dashboard", 7),
            ("\(workRoot)/cloud-infra", 5),
            ("\(home)/Code/personal/notes-app", 8),
            ("\(home)/Projects/home-sensors", 4),
            ("\(home)/Code/oss/pacer", 12),
            ("\(home)/Code/personal/dotfiles", 2),
        ]
        for (li, leaf) in leaves.enumerated() {
            let (path, base) = leaf
            for d in 0..<42 {
                guard let day = cal.date(byAdding: .day, value: -d, to: startOfToday) else { continue }
                if d != 0 && noise(d &* 11 &+ li &* 3) < 0.18 { continue }   // gap days
                let ds = TokenSample.formatDate(day)
                let cost = base * (0.45 + 1.1 * noise(d &* 7 &+ li))
                let input = Int64(cost * 9_000)
                let output = Int64(cost * 2_400)
                ctx.insert(ProjectDailyAggregate(
                    projectPath: path,
                    date: ds,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: input * 6,
                    totalCostUSD: cost,
                    sessionCount: 1 + Int(noise(d &+ li) * 3),
                    modelCount: 2,
                    lastActive: day
                ))
            }
        }

        let collections = [
            ProjectCollection(
                id: "acme", name: "Acme Corp", sortOrder: 40,
                rules: [workRoot]
            ),
            ProjectCollection(
                id: "side", name: "Side Projects", sortOrder: 30,
                includePaths: [
                    "\(home)/Code/personal/notes-app",
                    "\(home)/Projects/home-sensors",
                    "\(workRoot)/firmware",   // overlaps Acme Corp on purpose
                ]
            ),
            ProjectCollection(
                id: "oss", name: "Open Source", sortOrder: 20,
                includePaths: ["\(home)/Code/oss/pacer"]
            ),
            ProjectCollection(
                id: "client", name: "Client: Globex", sortOrder: 50,
                includePaths: ["\(home)/Code/oss/pacer"],
                childCollectionIDs: ["acme"]   // nesting
            ),
        ]
        collections.forEach { ctx.insert($0) }
    }

    /// Prior days' hourly rollups (~70 days) so the intelligence engine has
    /// the day-shape history it learns from — without these it reports
    /// "0 days observed" in the screenshots. Mirrors the daily seeder's
    /// weekday/weekend rhythm with a midday plateau; total per day tracks
    /// the same noise so daily and hourly stay roughly consistent.
    private static func seedPriorHourly(
        _ ctx: ModelContext, startOfToday: Date, cal: Calendar
    ) {
        for d in 1..<70 {
            guard let day = cal.date(byAdding: .day, value: -d, to: startOfToday) else { continue }
            if noise(d &* 7 &+ 5) < 0.12 { continue }          // same gap days as daily
            let ds = TokenSample.formatDate(day)
            let weekday = cal.component(.weekday, from: day)
            let isWeekend = (weekday == 1 || weekday == 7)
            let r = noise(d)
            var dayCost = (isWeekend ? 30.0 : 110.0) * (0.55 + 0.9 * r)
            if weekday == 3 || weekday == 4 { dayCost *= 1.25 }
            // Spread over 8am–8pm with the same broad midday plateau.
            var weights: [Double] = []
            for h in 8...20 {
                let dist = abs(Double(h) - 13.5)
                weights.append(max(0.15, min(1.0, 1.15 - dist / 7.0)) * (0.7 + 0.6 * noise(h &+ d)))
            }
            let totalW = weights.reduce(0, +)
            for (i, h) in (8...20).enumerated() {
                let share = dayCost * weights[i] / totalW
                insertHourly(ctx, date: ds, hour: h, model: opus, cost: share * 0.9)
                insertHourly(ctx, date: ds, hour: h, model: sonnet, cost: share * 0.1)
            }
        }
    }

    /// Today's hourly breakdown for the timeline card — active ~7am to
    /// now, a broad midday plateau (noon–4pm peak) rather than a sharp
    /// triangle, matching the real hourly distribution. Only seed hours
    /// up to *now* — the Live Activity card sums the current + previous
    /// hour buckets for its "last hour" rate and end-of-day projection,
    /// so seeding future hours would inflate both.
    private static func seedTodayHourly(
        _ ctx: ModelContext, today: String, now: Date, cal: Calendar
    ) {
        let endHour = cal.component(.hour, from: now)
        let startHour = endHour >= 7 ? 7 : max(0, endHour - 2)
        guard startHour <= endHour else { return }
        for h in startHour...endHour {
            // Broad midday plateau: flat-ish 11–16, tapering at the edges.
            let dist = abs(Double(h) - 13.5)
            let intensity = max(0.2, min(1.0, 1.15 - dist / 7.0))
            let opusCost = 13.0 * intensity * (0.7 + 0.6 * noise(h))
            let sonnetCost = 1.4 * intensity * (0.7 + noise(h &+ 99))
            insertHourly(ctx, date: today, hour: h, model: opus, cost: opusCost)
            insertHourly(ctx, date: today, hour: h, model: sonnet, cost: sonnetCost)
        }
    }

    /// Rate-limit trails for both windows.
    ///
    /// The chart plots utilization across the whole cycle (cycleStart →
    /// reset) against a straight 0→100% "ideal burn" reference line, so
    /// the seed has to (a) span the full cycle starting at 0% at
    /// `cycleStart`, and (b) tell a story worth showing. Utilization is
    /// cumulative within a cycle, so it only ever climbs — "falling back
    /// within pace" means going *flat* while the reference line keeps
    /// rising. The keyframes below trace exactly that: a burst that
    /// overshoots the pace line (ahead), a plateau that lets pace catch
    /// up (back behind), then another climb — so the colour bands all
    /// show up instead of a single straight diagonal.
    ///
    /// `now` lands partway through each cycle (≈60% of the 5-hour, ≈57%
    /// of the 7-day), and the final keyframe is the value the hero
    /// tiles / gauges / menu-bar readout display (42% and 61%).
    private static func seedRateLimits(_ ctx: ModelContext, now: Date) {
        // 5-hour: a steady, near-linear climb with a recent uptick, ending
        // ~32%. In real data the 5-hour window is rarely stressed (it
        // climbs a few points per decile and seldom nears the cap), so
        // here it stays comfortably behind the pace line — a healthy green
        // "you're fine" reading. `now` sits ≈60% through the cycle.
        let fiveHour = WindowSpec(
            window: "five_hour",
            resetsAt: now.addingTimeInterval(2 * 3_600),
            duration: 5 * 3_600,
            keyframes: [(0, 0), (0.12, 6), (0.25, 12), (0.38, 17),
                        (0.50, 22), (0.56, 26), (0.60, 32)]
        )
        // 7-day: the window that actually tells a story. Front-loaded —
        // a heavy first couple of days pull *ahead* of pace — then a
        // quiet midweek lets the pace line catch up (it falls back within
        // pace), then a recent push pulls ahead again, ending ~62% with
        // `now` ≈57% through. Mirrors the real weekly pattern (early-week
        // climb, midweek lull, late-week resurgence) and shows every pace
        // band: ahead → on-pace → behind → ahead.
        let sevenDay = WindowSpec(
            window: "seven_day",
            resetsAt: now.addingTimeInterval(3 * 86_400),
            duration: 7 * 86_400,
            keyframes: [(0, 0), (0.08, 14), (0.18, 29), (0.26, 34),
                        (0.36, 36), (0.46, 39), (0.52, 50), (0.55, 57), (0.57, 62)]
        )

        // Walk a single 5-minute grid (the real OAuth poll cadence, which
        // returns BOTH windows at once) from the earliest cycle start to
        // now, emitting each window's sample at the same timestamps. This
        // matters: the menu-bar popover / hero tiles read the most-recent
        // samples with a small fetch limit, so if one window were sampled
        // far less often it'd fall out of that window and read "collecting".
        let interval: TimeInterval = 5 * 60
        let start = min(fiveHour.cycleStart, sevenDay.cycleStart)
        var t = start
        var i = 0
        var last: [String: Double] = [:]
        while t <= now {
            for spec in [fiveHour, sevenDay] where t >= spec.cycleStart {
                let nowFrac = now.timeIntervalSince(spec.cycleStart) / spec.duration
                let frac = min(nowFrac, max(0, t.timeIntervalSince(spec.cycleStart) / spec.duration))
                var pct = interpolateKeyframes(spec.keyframes, at: frac)
                if frac > 0, frac < nowFrac { pct += noise(i &* 17 &+ spec.window.count) * 0.8 }
                pct = max(last[spec.window] ?? 0, min(99, pct))
                last[spec.window] = pct
                ctx.insert(RateLimitSample(
                    sampledAt: t, window: spec.window, usedPercentage: pct,
                    resetsAt: spec.resetsAt, source: "oauth"
                ))
            }
            t = t.addingTimeInterval(interval)
            i += 1
        }
    }

    /// Seed the scoped `limits[]` rows that become first-class pace columns.
    /// Fake data only. The two account-wide windows (a session + a weekly "All
    /// models") get a single latest-poll row — the fixed 5h/7d hero columns
    /// already own those, so the scoped column set filters them out. The
    /// per-model weekly windows each get a **full current-cycle history** (an
    /// hourly climb to their target), so every scoped column shows a real
    /// climbing actual line and the engine can forecast it — exactly like the
    /// 5h/7d hero windows. The hottest (Haiku) is flagged as the window
    /// currently in effect and carries an elevated severity, exercising the
    /// active dot + severity chip. More than two scoped windows also drives the
    /// N-column responsive grid.
    private static func seedUsageLimits(_ ctx: ModelContext, now: Date) {
        let sessionReset = now.addingTimeInterval(2 * 3600 + 19 * 60)
        let weeklyReset = now.addingTimeInterval(2 * 86_400 + 4 * 3600)
        let weeklyDuration: TimeInterval = 7 * 86_400

        // Account-wide windows — one latest-poll row each (excluded from the
        // scoped columns; they duplicate the 5h/7d hero windows).
        let accountWide: [(kind: String, group: String, pct: Double, reset: Date)] = [
            ("session",    "session", 39, sessionReset),
            ("weekly_all", "weekly",  71, weeklyReset),
        ]
        for a in accountWide {
            ctx.insert(UsageLimitSample(
                sampledAt: now, identity: "\(a.kind)||", kind: a.kind, group: a.group,
                label: "All models", percent: a.pct, resetsAt: a.reset,
                severity: "normal", isActive: false,
                modelId: nil, modelDisplayName: nil, surface: nil, source: "oauth"))
        }

        // Scoped per-model weekly windows — the first-class pace columns.
        // (model, target%, active/in-effect, severity)
        let scoped: [(model: String, target: Double, active: Bool, severity: String)] = [
            ("Haiku",  93, true,  "warning"),
            ("Opus",   84, false, "normal"),
            ("Fable",  49, false, "normal"),
            ("Sonnet", 22, false, "normal"),
        ]
        let cycleStart = weeklyReset.addingTimeInterval(-weeklyDuration)
        let elapsed = now.timeIntervalSince(cycleStart)
        let interval: TimeInterval = 3600
        for (idx, s) in scoped.enumerated() {
            let identity = "weekly_scoped|\(s.model)|"
            func insert(at t: Date, pct: Double) {
                ctx.insert(UsageLimitSample(
                    sampledAt: t, identity: identity, kind: "weekly_scoped", group: "weekly",
                    label: s.model, percent: pct, resetsAt: weeklyReset,
                    severity: s.severity, isActive: s.active,
                    modelId: nil, modelDisplayName: s.model, surface: nil, source: "oauth"))
            }
            var t = cycleStart
            var i = 0
            var last = 0.0
            while t < now {
                let frac = max(0, min(1, t.timeIntervalSince(cycleStart) / elapsed))
                // Mild concave ramp toward the target, monotonic, small jitter.
                var pct = s.target * (frac * (1.08 - 0.08 * frac))
                if frac > 0.02, frac < 0.98 { pct += noise(i &* 13 &+ idx &* 7) * 1.2 }
                pct = max(last, min(s.target, pct))
                last = pct
                insert(at: t, pct: pct)
                t = t.addingTimeInterval(interval)
                i += 1
            }
            // Final sample pinned to exactly `now` at the target — the
            // latest-batch anchor so the column/engine see this identity.
            insert(at: now, pct: s.target)
        }
    }

    private struct WindowSpec {
        let window: String
        let resetsAt: Date
        let duration: TimeInterval
        let keyframes: [(Double, Double)]
        var cycleStart: Date { resetsAt.addingTimeInterval(-duration) }
    }

    /// Piecewise-linear lookup over `(x, y)` keyframes sorted by `x`.
    private static func interpolateKeyframes(_ kf: [(Double, Double)], at x: Double) -> Double {
        guard let first = kf.first, let lastKf = kf.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= lastKf.0 { return lastKf.1 }
        for j in 1..<kf.count where x <= kf[j].0 {
            let (x0, y0) = kf[j - 1]
            let (x1, y1) = kf[j]
            let f = (x1 == x0) ? 0 : (x - x0) / (x1 - x0)
            return y0 + (y1 - y0) * f
        }
        return lastKf.1
    }

    /// A handful of sessions across recent projects. Real sessions run
    /// long (hours) and are overwhelmingly Opus; the first is "active"
    /// (last write seconds ago) so the freshness pill reads live.
    private static func seedSessions(_ ctx: ModelContext, now: Date) {
        let sessions: [(path: String, model: String, ageSeconds: Double, hours: Double, cost: Double)] = [
            ("/Users/dev/code/atlas-api", opus, 25, 6.5, 142.0),
            ("/Users/dev/code/web-dashboard", opus, 3 * 3_600, 4.0, 71.0),
            ("/Users/dev/code/ml-pipeline", opus, 9 * 3_600, 8.5, 96.0),
            ("/Users/dev/code/infra-terraform", sonnet, 26 * 3_600, 3.0, 38.0),
            ("/Users/dev/code/payments-svc", opus, 40 * 3_600, 5.5, 64.0),
            ("/Users/dev/dotfiles", haiku, 60 * 3_600, 1.5, 9.0),
        ]
        for (idx, s) in sessions.enumerated() {
            let last = now.addingTimeInterval(-s.ageSeconds)
            let first = last.addingTimeInterval(-s.hours * 3_600)
            let t = tokens(forCost: s.cost)
            ctx.insert(SessionInfo(
                sessionId: "screenshot-session-\(idx)",
                firstSeenAt: first,
                lastSeenAt: last,
                projectPath: s.path,
                ccVersion: "1.0.0",
                cumulativeCostUSD: s.cost,
                cumulativeInputTokens: t.input,
                cumulativeOutputTokens: t.output,
                cumulativeCacheReadTokens: t.cacheRead,
                cumulativeCacheCreation5mTokens: t.cache5m,
                cumulativeCacheCreation1hTokens: 0,
                topModel: s.model
            ))
        }
    }

    /// A few token samples timestamped in the last minute so freshness /
    /// live-activity surfaces read "active". Cache-heavy, output > input.
    private static func seedRecentTokens(_ ctx: ModelContext, now: Date) {
        let today = TokenSample.formatDate(now)
        for i in 0..<5 {
            let t = now.addingTimeInterval(-Double(i) * 30 - 25)
            ctx.insert(TokenSample(
                sampledAt: t,
                date: today,
                model: opus,
                inputTokens: 380,
                outputTokens: 9_400,
                cacheReadTokens: 2_900_000,
                cacheCreation5mTokens: 34_000,
                cacheCreation1hTokens: 0,
                sourceCostUSD: 2.1,
                dedupKey: "screenshot-token-\(i)",
                sessionId: "screenshot-session-0",
                projectPath: "/Users/dev/code/atlas-api"
            ))
        }
    }

    // MARK: helpers

    /// Token breakdown for a given dollar cost, shaped from real usage:
    /// prompt caching dominates (cache reads ≈ 280× input+output), and
    /// the *non-cached* input is tiny next to the generated output
    /// (output ≈ 30× input). The "Today's traffic" card and the cache
    /// hit-rate (~99.6%) fall straight out of these ratios.
    private static func tokens(forCost c: Double)
        -> (input: Int64, output: Int64, cacheRead: Int64, cache5m: Int64) {
        (Int64(c * 140), Int64(c * 4_200), Int64(c * 1_300_000), Int64(c * 15_000))
    }

    private static func insertDaily(
        _ ctx: ModelContext, date: String, model: String, cost: Double
    ) {
        let t = tokens(forCost: cost)
        ctx.insert(DailyAggregate(
            date: date, model: model,
            inputTokens: t.input, outputTokens: t.output,
            cacheReadTokens: t.cacheRead, cacheCreation5mTokens: t.cache5m,
            cacheCreation1hTokens: 0, totalCostUSD: cost
        ))
    }

    private static func insertHourly(
        _ ctx: ModelContext, date: String, hour: Int, model: String, cost: Double
    ) {
        let t = tokens(forCost: cost)
        ctx.insert(HourlyAggregate(
            date: date, hour: hour, model: model,
            inputTokens: t.input, outputTokens: t.output,
            cacheReadTokens: t.cacheRead, cacheCreation5mTokens: t.cache5m,
            cacheCreation1hTokens: 0, totalCostUSD: cost,
            sampleCount: 4 + Int(cost / 2)
        ))
    }

    /// Deterministic [0,1) pseudo-noise — no `Math.random`, so a re-run
    /// produces byte-identical data (modulo the absolute clock).
    private static func noise(_ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed &* 2_654_435_761 &+ 1))
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        return Double(x % 10_000) / 10_000.0
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// A macOS window titlebar — traffic-light buttons at the left, a faint
/// centered window title — prepended to window scenes so they read like a
/// real app-window screenshot.
/// Renders the redesigned collection editor with representative data so
/// `make screenshots` shows the rule live-preview, the disambiguated
/// member rows, and the color picker.
private struct CollectionEditorShowcase: View {
    var body: some View {
        let home = NSHomeDirectory()
        let known = [
            "\(home)/Code/work/acme-corp/api",
            "\(home)/Code/work/acme-corp/firmware",
            "\(home)/Code/work/acme-corp/web-dashboard",
            "\(home)/Code/work/acme-corp/cloud-infra",
            "\(home)/Code/personal/notes-app",
            "\(home)/Code/oss/pacer",
        ]
        var draft = CollectionEditorDraft()
        draft.name = "Acme Corp"
        draft.rules = ["\(home)/Code/work/acme-corp"]
        draft.includePaths = ["\(home)/Code/oss/pacer"]
        return CollectionEditorSheet(
            draft: draft,
            knownPaths: known,
            otherCollections: [("side", "Side Projects")],
            onSave: { _ in }
        )
    }
}

private struct MacWindowChrome: View {
    let title: String

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                dot(Color(red: 1.00, green: 0.37, blue: 0.34))   // close
                dot(Color(red: 1.00, green: 0.74, blue: 0.18))   // minimize
                dot(Color(red: 0.16, green: 0.80, blue: 0.27))   // zoom
                Spacer()
            }
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12)
    }
}

/// The whole menu-bar experience in one image: a slice of the macOS menu
/// bar carrying Pacer's readout (`MenuBarLabel`), with the click-down
/// popover (`MenuStatusContent`) hanging beneath it, right-aligned the way
/// it drops on screen. The bar is always dark (as the macOS menu bar is on
/// most setups); the popover follows the capture's colour scheme.
private struct MenuBarExperience: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 18) {
                Spacer(minLength: 40)
                MenuBarLabel()
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Color.black.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .environment(\.colorScheme, .dark)   // light chips on the dark bar

            MenuStatusContent()
                .frame(width: 300)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
                .padding(.trailing, 6)
        }
    }
}

/// A single composite image of the home-screen widget family — the real
/// widget views, fed fake `TimelineEntry` values, each framed at its
/// native size with the rounded corners + shadow widgets get on the
/// desktop. One image keeps the README compact while still showing the
/// range of widget options.
private struct WidgetGallery: View {
    private let small = CGSize(width: 158, height: 158)
    private let medium = CGSize(width: 348, height: 158)

    var body: some View {
        VStack(spacing: 22) {
            HStack(alignment: .top, spacing: 22) {
                tile(small) { TodayCostWidgetView(entry: ScreenshotEntries.todayCost) }
                tile(medium) { PaceGaugesWidgetView(entry: ScreenshotEntries.paceGauges) }
            }
            HStack(alignment: .top, spacing: 22) {
                tile(medium) { LiveSessionWidgetView(entry: ScreenshotEntries.liveSession) }
                tile(medium) { DailyChartWidgetView(entry: ScreenshotEntries.dailyChart) }
            }
            HStack(alignment: .top, spacing: 22) {
                tile(medium) { TopProjectsWidgetView(entry: ScreenshotEntries.topProjects) }
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private func tile(
        _ size: CGSize,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        content()
            .frame(width: size.width, height: size.height)
            // `.containerBackground(for: .widget)` is a no-op outside a
            // real widget, so paint the card fill ourselves.
            .background(PacerDesign.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 14, x: 0, y: 7)
    }
}

/// The two large widget families showing scoped per-model windows as
/// first-class rows / gauges alongside 5h and 7d — the widget half of the
/// "scoped windows are treated identically to 5h/7d" story. Hand-built entries
/// (the widget provider reads the real store, which is empty here).
private struct ScopedFirstClassWidgetGallery: View {
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            tile(w: 340, h: 384) {
                PaceChartWidgetView(entry: ScreenshotEntries.paceChartScopedLarge,
                                    forcedFamily: .systemLarge)
            }
            tile(w: 340, h: 384) {
                PaceGaugesWidgetView(entry: ScreenshotEntries.paceGaugesScopedLarge,
                                     forcedFamily: .systemLarge)
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private func tile(w: CGFloat, h: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(width: w, height: h)
            .background(PacerDesign.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 14, x: 0, y: 7)
    }
}

/// Deterministic fake `TimelineEntry` values for the widget gallery —
/// kept consistent with the dashboard seed (Opus-heavy, cache-dominated,
/// 5h ≈32% / 7d ≈62%, ~$124 today).
private enum ScreenshotEntries {
    private static let now = Date()
    static let opus = "claude-opus-4-7"

    static var todayCost: TodayCostEntry {
        TodayCostEntry(date: now, costUSD: 124.0, tokens: 540_000, modelCount: 3, isFresh: true)
    }

    static var paceGauges: PaceGaugesEntry {
        PaceGaugesEntry(
            date: now,
            fiveHour: .init(usedPct: 32, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: .init(usedPct: 62, resetsAt: now.addingTimeInterval(3 * 86_400)),
            window: .both
        )
    }

    /// Large pace-chart widget with scoped per-model windows as first-class
    /// rows below 5h/7d.
    static var paceChartScopedLarge: PaceChartEntry {
        PaceChartEntry(
            date: now,
            fiveHour: chartWindow(duration: 5 * 3600, usedPct: 32, projectTo: 46),
            sevenDay: chartWindow(duration: 7 * 86_400, usedPct: 62, projectTo: 88),
            scoped: [
                .init(label: "Haiku", state: chartWindow(duration: 7 * 86_400, usedPct: 93, projectTo: 100), isActive: true),
                .init(label: "Opus",  state: chartWindow(duration: 7 * 86_400, usedPct: 84, projectTo: 97), isActive: false),
            ],
            window: .both
        )
    }

    /// Large gauges widget with scoped per-model windows as ring gauges.
    static var paceGaugesScopedLarge: PaceGaugesEntry {
        let weeklyReset = now.addingTimeInterval(2 * 86_400 + 4 * 3600)
        let weeklyDur: TimeInterval = 7 * 86_400
        return PaceGaugesEntry(
            date: now,
            fiveHour: .init(usedPct: 32, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: .init(usedPct: 62, resetsAt: now.addingTimeInterval(3 * 86_400)),
            scoped: [
                .init(label: "Haiku",  usedPct: 93, resetsAt: weeklyReset, durationSeconds: weeklyDur, isActive: true),
                .init(label: "Opus",   usedPct: 84, resetsAt: weeklyReset, durationSeconds: weeklyDur, isActive: false),
                .init(label: "Fable",  usedPct: 49, resetsAt: weeklyReset, durationSeconds: weeklyDur, isActive: false),
                .init(label: "Sonnet", usedPct: 22, resetsAt: weeklyReset, durationSeconds: weeklyDur, isActive: false),
            ],
            window: .both
        )
    }

    /// A climbing actual line with a dashed linear projection to `projectTo` at
    /// reset — the shape a real window shows. `~62%` elapsed so the dashed
    /// segment is visible.
    private static func chartWindow(duration: TimeInterval, usedPct: Double, projectTo: Double) -> PaceChartEntry.WindowState {
        let resets = now.addingTimeInterval(duration * 0.38)
        let cycleStart = resets.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(cycleStart)
        let n = 12
        let points = (0..<n).map { i -> PaceChartView.Data.Point in
            let f = Double(i) / Double(n - 1)
            return .init(time: cycleStart.addingTimeInterval(elapsed * f),
                         value: usedPct * (f * (1.06 - 0.06 * f)))
        }
        let steps = 6
        let projection = (0...steps).map { i -> PaceChartView.Data.Point in
            let f = Double(i) / Double(steps)
            return .init(time: now.addingTimeInterval(resets.timeIntervalSince(now) * f),
                         value: min(100, usedPct + (projectTo - usedPct) * f))
        }
        let crossing: Date? = (projectTo > usedPct && projectTo >= 100)
            ? now.addingTimeInterval(resets.timeIntervalSince(now) * ((100 - usedPct) / (projectTo - usedPct)))
            : nil
        return PaceChartEntry.WindowState(
            chart: PaceChartView.Data(
                cycleStart: cycleStart, resetsAt: resets, durationSeconds: duration,
                points: points, usedPct: usedPct,
                projection: projection, projectionCrossesFullAt: crossing),
            resetsAt: resets)
    }

    static var liveSession: LiveSessionEntry {
        LiveSessionEntry(
            date: now,
            session: .init(
                projectDisplayName: "atlas-api",
                totalTokens: 9_400_000,
                costUSD: 142.0,
                topModel: opus,
                firstSeenAt: now.addingTimeInterval(-6.5 * 3600),
                lastSeenAt: now.addingTimeInterval(-30)
            )
        )
    }

    static var dailyChart: DailyChartEntry {
        // Weekday-driven with weekend dips and a spike — same shape as the
        // dashboard's 30-day chart.
        let cal = Calendar.current
        let days = (0..<14).map { i -> DailyChartEntry.DayCost in
            let day = cal.date(byAdding: .day, value: -(13 - i), to: now) ?? now
            let wd = cal.component(.weekday, from: day)
            let weekend = (wd == 1 || wd == 7)
            var cost = weekend ? 34.0 : 120.0
            cost *= 0.7 + 0.7 * Double((i * 7 + 3) % 11) / 11.0
            if i == 9 { cost *= 2.6 }          // a spike day
            return DailyChartEntry.DayCost(date: TokenSample.formatDate(day), cost: cost)
        }
        let total = days.reduce(0) { $0 + $1.cost }
        return DailyChartEntry(
            date: now, days: days,
            totalCostUSD: total,
            avgCostUSD: total / Double(days.count),
            todayCostUSD: days.last?.cost ?? 0,
            isFresh: true, range: .days14
        )
    }

    static var topProjects: TopProjectsEntry {
        let rows = [
            TopProjectsEntry.Row(displayName: "atlas-api", costUSD: 1_284.0),
            TopProjectsEntry.Row(displayName: "ml-pipeline", costUSD: 892.0),
            TopProjectsEntry.Row(displayName: "payments-svc", costUSD: 613.0),
            TopProjectsEntry.Row(displayName: "web-dashboard", costUSD: 421.0),
        ]
        return TopProjectsEntry(
            date: now, range: .days7,
            totalCostUSD: rows.reduce(0) { $0 + $1.costUSD } + 340,
            projectCount: 12,
            rows: rows, focus: nil
        )
    }
}
