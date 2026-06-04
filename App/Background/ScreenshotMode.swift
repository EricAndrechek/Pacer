import AppKit
import SwiftUI
import SwiftData
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

        // Order out any stray scene window SwiftUI may have created so
        // nothing flashes on screen. We capture our own hosting views
        // directly, so other windows are irrelevant to the output.
        for window in NSApp.windows { window.orderOut(nil) }

        // Each scene in both appearances. The opaque background applied
        // in `render` is what makes dark mode work: a SwiftUI ScrollView's
        // own background is clear, so the dark-mode (white) page-title text
        // would otherwise flatten onto the transparent backing and survive
        // only as its grey anti-alias fringe — the "ghost" header.
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "-dark" : ""
            await render(
                "dashboard\(suffix)",
                size: CGSize(width: 1280, height: 880),
                scheme: scheme, container: container
            ) {
                ContentView()
            }
            await render(
                "history\(suffix)",
                size: CGSize(width: 1180, height: 860),
                scheme: scheme, container: container
            ) {
                HistoryView()
            }
            await render(
                "menubar\(suffix)",
                size: CGSize(width: 360, height: 340),
                scheme: scheme, container: container
            ) {
                MenuPopoverPreview()
            }
        }

        log("screenshots complete")
    }

    /// Host `content` in an off-screen window, let the SwiftUI lifecycle
    /// run, then snapshot it to a PNG.
    private static func render(
        _ name: String,
        size: CGSize,
        scheme: ColorScheme,
        container: ModelContainer,
        @ViewBuilder _ content: () -> some View
    ) async {
        let root = AnyView(
            content()
                // Opaque window-colored backing behind everything so
                // dark-mode white text doesn't flatten onto a transparent
                // (→ white) background and ghost. Matches the real app
                // window background, so it also improves card separation
                // in light mode.
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(scheme)
                .modelContainer(container)
        )

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)

        // Borderless, far off-screen, never key/active — no focus steal,
        // nothing visible, but `orderFrontRegardless` realizes the view
        // tree so onAppear/@Query/Charts actually run.
        let window = NSWindow(
            contentRect: NSRect(x: -60_000, y: -60_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()

        // Spin the run loop so SwiftUI mounts, @Query fetches land, the
        // @State scan-tick caches refresh, and Charts lay out. Generous
        // settle so appear/content transitions (e.g. the page-title text
        // animating in) finish before we snapshot — a mid-transition
        // capture double-draws the header text.
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
        let url = outputDirectory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
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
    private static let opus = "claude-opus-4-6"
    private static let sonnet = "claude-sonnet-4-6"
    private static let haiku = "claude-haiku-4-5"

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
        seedTodayHourly(ctx, today: TokenSample.formatDate(startOfToday), now: now, cal: cal)
        seedRateLimits(ctx, now: now)
        seedSessions(ctx, now: now)
        seedRecentTokens(ctx, now: now)

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

    /// Six months of per-model daily rollups with weekday/weekend
    /// variation, a gentle recent-uptick ramp, and occasional gap days
    /// so the heatmap and 30-day chart look organic.
    private static func seedDailyAggregates(
        _ ctx: ModelContext, startOfToday: Date, cal: Calendar
    ) {
        for d in 0..<182 {
            guard let day = cal.date(byAdding: .day, value: -d, to: startOfToday) else { continue }
            // ~10% gap days (no usage), but today always has data.
            if d != 0 && noise(d &* 7 &+ 5) < 0.10 { continue }

            let ds = TokenSample.formatDate(day)
            let weekday = cal.component(.weekday, from: day)
            let isWeekend = (weekday == 1 || weekday == 7)
            let r = noise(d)
            let ramp = 0.7 + 0.5 * Double(182 - d) / 182.0
            var dayCost = ((isWeekend ? 7.0 : 26.0) + r * (isWeekend ? 9.0 : 30.0)) * ramp
            if d == 0 { dayCost = 23.4 }  // a believable mid-day total

            let opusCost = dayCost * (0.46 + 0.12 * r)
            let sonnetCost = dayCost * 0.34
            let haikuCost = max(0.2, dayCost - opusCost - sonnetCost)
            insertDaily(ctx, date: ds, model: opus, cost: opusCost)
            insertDaily(ctx, date: ds, model: sonnet, cost: sonnetCost)
            insertDaily(ctx, date: ds, model: haiku, cost: haikuCost)
        }
    }

    /// Today's hourly breakdown (workday-shaped) for the timeline card.
    /// Only seed hours up to *now* — the Live Activity card sums the
    /// current + previous hour buckets for its "last hour" rate and the
    /// end-of-day projection, so seeding future hours would inflate both.
    private static func seedTodayHourly(
        _ ctx: ModelContext, today: String, now: Date, cal: Calendar
    ) {
        let endHour = cal.component(.hour, from: now)
        let startHour = endHour >= 8 ? 8 : max(0, endHour - 2)
        guard startHour <= endHour else { return }
        for h in startHour...endHour {
            // Triangular activity peaking around 1pm.
            let intensity = max(0.15, 1.0 - abs(Double(h) - 13.0) / 6.0)
            let opusCost = 1.6 * intensity * (0.8 + noise(h))
            let sonnetCost = 0.9 * intensity * (0.8 + noise(h &+ 99))
            insertHourly(ctx, date: today, hour: h, model: opus, cost: opusCost)
            insertHourly(ctx, date: today, hour: h, model: sonnet, cost: sonnetCost)
        }
    }

    /// Rate-limit trails for both windows. The latest 5h sits at 42%
    /// (a touch behind pace) and the latest 7d at 61% (a touch ahead),
    /// so the pace tiles show some color rather than a flat reading.
    private static func seedRateLimits(_ ctx: ModelContext, now: Date) {
        let sevenDayReset = now.addingTimeInterval(3 * 86_400)
        for i in 0...16 {
            let t = now.addingTimeInterval(-Double(16 - i) * 5.5 * 3_600)
            let pct = 18.0 + Double(i) / 16.0 * 43.0
            ctx.insert(RateLimitSample(
                sampledAt: t, window: "seven_day", usedPercentage: pct,
                resetsAt: sevenDayReset, source: "oauth"
            ))
        }
        let fiveHourReset = now.addingTimeInterval(2 * 3_600)
        for i in 0...12 {
            let t = now.addingTimeInterval(-Double(12 - i) * 14 * 60)
            let pct = 6.0 + Double(i) / 12.0 * 36.0
            ctx.insert(RateLimitSample(
                sampledAt: t, window: "five_hour", usedPercentage: pct,
                resetsAt: fiveHourReset, source: "oauth"
            ))
        }
    }

    /// A handful of sessions across recent projects; the first is "active"
    /// (last write seconds ago) so the freshness pill reads live.
    private static func seedSessions(_ ctx: ModelContext, now: Date) {
        let sessions: [(path: String, model: String, ageSeconds: Double)] = [
            ("/Users/dev/code/atlas-api", opus, 25),
            ("/Users/dev/code/web-dashboard", sonnet, 3 * 3_600),
            ("/Users/dev/code/ml-pipeline", opus, 9 * 3_600),
            ("/Users/dev/code/infra-terraform", sonnet, 26 * 3_600),
            ("/Users/dev/dotfiles", haiku, 50 * 3_600),
        ]
        for (idx, s) in sessions.enumerated() {
            let last = now.addingTimeInterval(-s.ageSeconds)
            let first = last.addingTimeInterval(-Double(2 + idx) * 3_600)
            let cost = 6.0 + noise(idx &* 31) * 18.0
            ctx.insert(SessionInfo(
                sessionId: "screenshot-session-\(idx)",
                firstSeenAt: first,
                lastSeenAt: last,
                projectPath: s.path,
                ccVersion: "1.0.0",
                cumulativeCostUSD: cost,
                cumulativeInputTokens: Int64(cost * 60_000),
                cumulativeOutputTokens: Int64(cost * 22_000),
                cumulativeCacheReadTokens: Int64(cost * 900_000),
                cumulativeCacheCreation5mTokens: Int64(cost * 8_000),
                cumulativeCacheCreation1hTokens: 0,
                topModel: s.model
            ))
        }
    }

    /// A few token samples timestamped in the last minute so freshness /
    /// live-activity surfaces read "active".
    private static func seedRecentTokens(_ ctx: ModelContext, now: Date) {
        let today = TokenSample.formatDate(now)
        for i in 0..<5 {
            let t = now.addingTimeInterval(-Double(i) * 30 - 25)
            ctx.insert(TokenSample(
                sampledAt: t,
                date: today,
                model: i.isMultiple(of: 2) ? opus : sonnet,
                inputTokens: 4_200,
                outputTokens: 1_800,
                cacheReadTokens: 120_000,
                cacheCreation5mTokens: 3_400,
                cacheCreation1hTokens: 0,
                sourceCostUSD: 0.42,
                dedupKey: "screenshot-token-\(i)",
                sessionId: "screenshot-session-0",
                projectPath: "/Users/dev/code/atlas-api"
            ))
        }
    }

    // MARK: helpers

    private static func insertDaily(
        _ ctx: ModelContext, date: String, model: String, cost: Double
    ) {
        ctx.insert(DailyAggregate(
            date: date, model: model,
            inputTokens: Int64(cost * 60_000),
            outputTokens: Int64(cost * 22_000),
            cacheReadTokens: Int64(cost * 900_000),
            cacheCreation5mTokens: Int64(cost * 8_000),
            cacheCreation1hTokens: 0,
            totalCostUSD: cost
        ))
    }

    private static func insertHourly(
        _ ctx: ModelContext, date: String, hour: Int, model: String, cost: Double
    ) {
        ctx.insert(HourlyAggregate(
            date: date, hour: hour, model: model,
            inputTokens: Int64(cost * 60_000),
            outputTokens: Int64(cost * 22_000),
            cacheReadTokens: Int64(cost * 900_000),
            cacheCreation5mTokens: Int64(cost * 8_000),
            cacheCreation1hTokens: 0,
            totalCostUSD: cost,
            sampleCount: 3 + Int(cost)
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

/// Dropdown-styled wrapper around the real menu-bar content so the
/// `menubar.png` reads like the popover users actually see, rather than
/// a bare floating column.
private struct MenuPopoverPreview: View {
    var body: some View {
        DayKeyedContent {
            MenuStatusContent()
        }
        .frame(width: 300)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        )
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
