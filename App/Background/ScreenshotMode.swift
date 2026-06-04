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

        // A richer menu-bar readout for the status-bar shot than the
        // default (icon + 5-hour %).
        PacerSettings.store.set(
            "icon,five_hour_pct,seven_day_pct,today_cost",
            forKey: PacerSettings.Key.menuBarChips
        )

        // Window scenes — framed like a real macOS window screenshot:
        // rounded corners + a soft drop shadow on a transparent margin.
        await capture("dashboard", width: 1280, height: 880, scheme: .light,
                      card: true, container: container) { ContentView() }
        await capture("dashboard-dark", width: 1280, height: 880, scheme: .dark,
                      card: true, container: container) { ContentView() }
        await capture("history", width: 1180, height: 860, scheme: .light,
                      card: true, container: container) { HistoryView() }

        // Menu-bar popover — tightly cropped to its intrinsic size.
        await capture("menubar", width: 280, height: nil, scheme: .light,
                      card: true, cornerRadius: 12, container: container) { MenuStatusContent() }
        await capture("menubar-dark", width: 280, height: nil, scheme: .dark,
                      card: true, cornerRadius: 12, container: container) { MenuStatusContent() }

        // The menu-bar item itself (the status-bar readout chips), and the
        // home-screen widget family — both self-decorated, captured on a
        // transparent canvas so they drop into the README cleanly.
        await capture("statusbar", width: nil, height: nil, scheme: .dark,
                      card: false, container: container) { StatusBarPreview() }
        await capture("widgets", width: nil, height: nil, scheme: .light,
                      card: false, container: container) { WidgetGallery() }

        log("screenshots complete")
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
        container: ModelContainer,
        @ViewBuilder _ content: () -> some View
    ) async {
        let margin: CGFloat = card ? 56 : 28
        let sized = content()
            .modelContainer(container)
            .frame(width: width, height: height)

        let decorated: AnyView
        if card {
            decorated = AnyView(
                sized
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 12)
            )
        } else {
            decorated = AnyView(sized)
        }
        let root = AnyView(decorated.padding(margin).preferredColorScheme(scheme))

        let hosting = NSHostingView(rootView: root)
        // Lay out at a generous temp frame so `fittingSize` resolves any
        // intrinsic dimension, then settle on the final size.
        let tempW = width.map { $0 + 2 * margin } ?? 4000
        let tempH = height.map { $0 + 2 * margin } ?? 4000
        hosting.frame = NSRect(x: 0, y: 0, width: tempW, height: tempH)
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let finalSize = CGSize(
            width: width.map { $0 + 2 * margin } ?? ceil(fit.width),
            height: height.map { $0 + 2 * margin } ?? ceil(fit.height)
        )
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

/// The menu-bar item's readout (`MenuBarLabel`) on a dark bar that
/// stands in for the macOS menu bar, so `statusbar.png` shows what the
/// chips look like up top.
private struct StatusBarPreview: View {
    var body: some View {
        MenuBarLabel()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.82))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
            )
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

/// Deterministic fake `TimelineEntry` values for the widget gallery.
private enum ScreenshotEntries {
    private static let now = Date()
    static let opus = "claude-opus-4-6"

    static var todayCost: TodayCostEntry {
        TodayCostEntry(date: now, costUSD: 23.40, tokens: 1_900_000, modelCount: 3, isFresh: true)
    }

    static var paceGauges: PaceGaugesEntry {
        PaceGaugesEntry(
            date: now,
            fiveHour: .init(usedPct: 42, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: .init(usedPct: 61, resetsAt: now.addingTimeInterval(3 * 86_400)),
            window: .both
        )
    }

    static var liveSession: LiveSessionEntry {
        LiveSessionEntry(
            date: now,
            session: .init(
                projectDisplayName: "atlas-api",
                totalTokens: 486_000,
                costUSD: 6.20,
                topModel: opus,
                firstSeenAt: now.addingTimeInterval(-2 * 3600),
                lastSeenAt: now.addingTimeInterval(-30)
            )
        )
    }

    static var dailyChart: DailyChartEntry {
        let days = (0..<14).map { i -> DailyChartEntry.DayCost in
            let day = Calendar.current.date(byAdding: .day, value: -(13 - i), to: now) ?? now
            let cost = 14.0 + Double((i * 7) % 23) + (i.isMultiple(of: 3) ? 6.0 : 0)
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
            TopProjectsEntry.Row(displayName: "atlas-api", costUSD: 142.80),
            TopProjectsEntry.Row(displayName: "web-dashboard", costUSD: 96.40),
            TopProjectsEntry.Row(displayName: "ml-pipeline", costUSD: 71.10),
            TopProjectsEntry.Row(displayName: "infra-terraform", costUSD: 38.25),
        ]
        return TopProjectsEntry(
            date: now, range: .days7,
            totalCostUSD: rows.reduce(0) { $0 + $1.costUSD },
            projectCount: rows.count,
            rows: rows, focus: nil
        )
    }
}
