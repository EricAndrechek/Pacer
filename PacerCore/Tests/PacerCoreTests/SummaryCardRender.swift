import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

/// Renders `PacerSummaryCard` — History's first card and both detail
/// modals' — to PNGs, light and dark, at History's width and a modal's, for
/// every range (a sparse and a busy week, 30 and 90 days, a year in weeks, a
/// two-day-old install and two years), a day and a project. Off by default;
/// set `PACER_RENDER_UI` to an output directory:
///
///     PACER_RENDER_UI=/tmp/pacer-ui swift test --filter SummaryCardRender
@MainActor
@Suite("Summary card render", .enabled(if: ProcessInfo.processInfo.environment["PACER_RENDER_UI"] != nil))
struct SummaryCardRender {

    private var outputDir: URL {
        let path = ProcessInfo.processInfo.environment["PACER_RENDER_UI"] ?? NSTemporaryDirectory()
        let dir: String = path == "1" ? NSTemporaryDirectory() : path
        return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("summary", isDirectory: true)
    }

    private static let today = "2026-10-22"
    private static let year = 2026

    /// A deterministic wobble in 0...1, so the fixtures look like real use
    /// without being random between runs.
    private static func wobble(_ i: Int, _ salt: Double) -> Double {
        let v: Double = sin(Double(i) * 1.37 + salt) * 0.5 + 0.5
        return v
    }

    /// Cache reads ~77% of the cost and ~98% of the tokens, as on a real
    /// store.
    static let heavy = CostBreakdown(
        cost: CostComponents(
            input: 8.12, output: 1_310.4, cacheRead: 12_603.12,
            cacheWrite5m: 1_512.75, cacheWrite1h: 978.3),
        tokens: TokenBreakdown(
            inputTokens: 1_623_000, outputTokens: 52_400_000,
            cacheReadTokens: 21_512_345_678,
            cacheCreation5mTokens: 242_000_000, cacheCreation1hTokens: 97_800_000))

    static let light = CostBreakdown(
        cost: CostComponents(input: 0.04, output: 18.2, cacheRead: 61.7, cacheWrite5m: 14.9),
        tokens: TokenBreakdown(
            inputTokens: 8_100, outputTokens: 728_000,
            cacheReadTokens: 123_400_000, cacheCreation5mTokens: 2_380_000))

    /// The card's model for a day strip, through the same helpers the
    /// screens call: each day's height its cost.
    private static func dayModel(
        _ breakdown: CostBreakdown, stats: [PacerSummaryFact],
        cost: [String: Double], from start: String
    ) -> PacerSummaryModel {
        let a = PeriodActivity.days(active: Set(cost.keys), cost: cost, from: start, through: today)
        return PacerSummaryModel(
            breakdown: breakdown, stats: stats, activity: a,
            span: pacerActivitySpan(a) { pacerFactDay($0, currentYear: year) },
            axis: pacerDayAxis(a, today: today, currentYear: year),
            cellHelp: pacerActivityCellHelp(a, currentYear: year))
    }

    /// The first day of "the last N days" on `today`, as `TimeRange.since`
    /// cuts it.
    private static func rangeStart(_ range: TimeRange) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let noon: Date = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12)) ?? Date()
        let since: Date = range.since(now: noon, calendar: cal) ?? noon
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: since)
    }

    static func busy90() -> PacerSummaryModel {
        let start: String = rangeStart(.ninetyDays)
        let keys: [String] = PeriodActivity.dayKeys(from: start, through: today)
        var cost: [String: Double] = [:]
        for (i, k) in keys.enumerated() {
            // A holiday week and a few days off.
            let idle: Bool = (i >= 30 && i <= 35) || i == 12 || i == 61 || i == 75
            if idle { continue }
            let usd: Double = 20 + 320 * wobble(i, 0.4) * wobble(i, 2.1)
            cost[k] = usd
        }
        return dayModel(heavy, stats: [.init("sessions", "1,284"), .init("projects", "37"), .init("models", "9")],
                        cost: cost, from: start)
    }

    static func month30() -> PacerSummaryModel {
        let start: String = rangeStart(.thirtyDays)
        let keys: [String] = PeriodActivity.dayKeys(from: start, through: today)
        var cost: [String: Double] = [:]
        for (i, k) in keys.enumerated() where wobble(i, 2.6) > 0.2 {
            cost[k] = 15 + 260 * wobble(i, 0.9)
        }
        return dayModel(heavy, stats: [.init("sessions", "402"), .init("projects", "18"), .init("models", "6")],
                        cost: cost, from: start)
    }

    /// A week with three days of use, the last one three days ago.
    static func sparseWeek() -> PacerSummaryModel {
        let cost: [String: Double] = ["2026-10-16": 31.5, "2026-10-17": 112.2, "2026-10-19": 46.3]
        return dayModel(light + light, stats: [.init("sessions", "9"), .init("projects", "3"), .init("models", "2")],
                        cost: cost, from: rangeStart(.sevenDays))
    }

    /// A busy week, every day but Sunday.
    static func busyWeek() -> PacerSummaryModel {
        let keys: [String] = PeriodActivity.dayKeys(from: rangeStart(.sevenDays), through: today)
        var cost: [String: Double] = [:]
        for (i, k) in keys.enumerated() where i != 2 {
            cost[k] = 40 + 210 * wobble(i, 1.3)
        }
        return dayModel(heavy, stats: [.init("sessions", "96"), .init("projects", "8"), .init("models", "4")],
                        cost: cost, from: rangeStart(.sevenDays))
    }

    /// Installed yesterday: Lifetime is two days.
    static func newInstall() -> PacerSummaryModel {
        let cost: [String: Double] = ["2026-10-21": 38.4, "2026-10-22": 56.4]
        return dayModel(light, stats: [.init("sessions", "8"), .init("projects", "2"), .init("models", "1")],
                        cost: cost, from: "2026-10-21")
    }

    /// A year, bucketed into weeks.
    static func year365() -> PacerSummaryModel {
        let start: String = rangeStart(.oneYear)
        let keys: [String] = PeriodActivity.dayKeys(from: start, through: today)
        var cost: [String: Double] = [:]
        for (i, k) in keys.enumerated() where wobble(i, 0.9) > 0.3 && !(i > 150 && i < 172) {
            let ramp: Double = Double(i) / Double(keys.count)
            cost[k] = 10 + 300 * ramp * wobble(i, 1.7)
        }
        return dayModel(heavy, stats: [.init("sessions", "4,120"), .init("projects", "96"), .init("models", "14")],
                        cost: cost, from: start)
    }

    /// Two years of history, bucketed into two-week cells.
    static func lifetime() -> PacerSummaryModel {
        let keys: [String] = PeriodActivity.dayKeys(from: "2024-09-02", through: today)
        var cost: [String: Double] = [:]
        for (i, k) in keys.enumerated() where wobble(i, 0.9) > 0.35 && !(i > 200 && i < 260) {
            let ramp: Double = Double(i) / Double(keys.count)
            cost[k] = 5 + 280 * ramp * wobble(i, 1.7)
        }
        return dayModel(heavy, stats: [.init("sessions", "6,812"), .init("projects", "142"), .init("models", "17")],
                        cost: cost, from: "2024-09-02")
    }

    static func project30() -> PacerSummaryModel {
        let start: String = rangeStart(.thirtyDays)
        let keys: [String] = PeriodActivity.dayKeys(from: start, through: today)
        var cost: [String: Double] = [:]
        for (i, k) in keys.enumerated() where wobble(i, 1.1) > 0.28 && i < keys.count - 1 {
            cost[k] = 30 + 900 * wobble(i, 0.7)
        }
        return dayModel(heavy, stats: [.init("sessions", "37"), .init("models", "4"), .init("per active day", "$745")],
                        cost: cost, from: start)
    }

    /// A project over the last 7 days: the strip that had no caption.
    static func project7() -> PacerSummaryModel {
        let cost: [String: Double] = ["2026-10-17": 84.1, "2026-10-18": 212.6, "2026-10-21": 133.9]
        return dayModel(light, stats: [.init("sessions", "6"), .init("models", "2"), .init("per active day", "$143")],
                        cost: cost, from: rangeStart(.sevenDays))
    }

    static func day() -> PacerSummaryModel {
        let cost: [Int: Double] = [9: 4.2, 10: 11.8, 11: 7.5, 14: 3.1, 15: 16.4, 16: 21.9, 17: 9.3,
                                   21: 6.2, 22: 12.7, 23: 1.8]
        let a = PeriodActivity.hours(active: Set(cost.keys), cost: cost)
        return PacerSummaryModel(
            breakdown: light,
            stats: [.init("sessions", "12"), .init("models", "3"), .init("projects", "4")],
            activity: a,
            span: pacerActivitySpan(a) { pacerHourLabel(Int($0) ?? 0) },
            axis: pacerHourAxis(),
            cellHelp: pacerActivityCellHelp(a, currentYear: year))
    }

    // MARK: Rendering

    private func render(_ view: some View, width: CGFloat, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let framed = view
                .frame(width: width - 32)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var image: CGImage?
            appearance?.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            let cg = try #require(image)
            let rep = NSBitmapImageRep(cgImage: cg)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: outputDir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    /// History's width (the page at its usual window size) and a Day
    /// modal's (612 pt card, 644 with this render's padding).
    @Test func historyCards() throws {
        let cards: [(String, String, PacerSummaryModel)] = [
            ("sparse7", "Last 7 days", Self.sparseWeek()),
            ("busy7", "Last 7 days", Self.busyWeek()),
            ("month30", "Last 30 days", Self.month30()),
            ("busy90", "Last 90 days", Self.busy90()),
            ("year", "Last 12 months", Self.year365()),
            ("new2", "Lifetime", Self.newInstall()),
            ("lifetime", "Lifetime", Self.lifetime()),
        ]
        for (name, title, model) in cards {
            try render(PacerSummaryCard(title, model: model), width: 792, name: "history-\(name)")
            try render(PacerSummaryCard(title, model: model), width: 644, name: "narrow-\(name)")
        }
    }

    @Test func modalCards() throws {
        try render(PacerSummaryCard(model: Self.day()) {
            EmptyView()
        }, width: 644, name: "day-modal")
        try render(PacerSummaryCard(model: Self.project30()) {
            Chip(text: "git", systemImage: "arrow.triangle.branch", tint: .secondary, size: .compact)
        }, width: 744, name: "project-modal")
        try render(PacerSummaryCard(model: Self.project7()) {
            Chip(text: "git", systemImage: "arrow.triangle.branch", tint: .secondary, size: .compact)
        }, width: 744, name: "project-modal-7d")
        // A day with no rows: the zeros, the empty strip, no breakdown.
        let empty = PacerSummaryModel(
            breakdown: .zero,
            stats: [.init("sessions", "0"), .init("models", "0"), .init("projects", "0")],
            activity: PeriodActivity.hours(active: []),
            axis: pacerHourAxis())
        try render(PacerSummaryCard(model: empty), width: 644, name: "day-modal-empty")
    }

    /// The chart hover card, with the cache line's input/output split, and
    /// with top models under the parts, their numbers in the parts' columns.
    @Test func hoverCard() throws {
        let card = PacerCostHoverCard(title: "Thu, Oct 2", breakdown: Self.light)
        try render(card, width: PacerCostHoverCard.idealWidth + 32, name: "hover-card")
        let models: [PacerChartModelCost] = [
            PacerChartModelCost(model: "claude-opus-4-7", usd: 71.3, share: 0.752, tokens: 98_400_000),
            PacerChartModelCost(model: "claude-sonnet-4-6", usd: 23.5, share: 0.248, tokens: 28_100_000),
        ]
        let withModels = PacerCostHoverCard(title: "Thu, Oct 2", breakdown: Self.light, topModels: models)
        try render(withModels, width: PacerCostHoverCard.idealWidth + 32, name: "hover-card-models")
    }
}
