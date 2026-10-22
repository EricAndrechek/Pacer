import AppKit
import Foundation
import SwiftUI
import Testing
import PacerCore
@testable import PacerUI

/// Renders the shared stacked-by-part chart and its hover card to PNGs, in
/// light and dark, so the component can be looked at without launching the
/// app. Off by default; set `PACER_RENDER_UI` to an output directory:
///
///     PACER_RENDER_UI=/tmp/pacer-ui swift test --filter StackedPartChartRender
@MainActor
@Suite("Stacked part chart render", .enabled(if: ProcessInfo.processInfo.environment["PACER_RENDER_UI"] != nil))
struct StackedPartChartRender {

    private var outputDir: URL {
        let path = ProcessInfo.processInfo.environment["PACER_RENDER_UI"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Fixtures

    /// A deterministic wobble in 0...1, so the fixtures look like real usage
    /// without being random between runs.
    private static func wobble(_ i: Int, _ salt: Double) -> Double {
        let v: Double = sin(Double(i) * 1.37 + salt) * 0.5 + 0.5
        return v
    }

    /// A bucket shaped like a real store's: cache reads most of the bill,
    /// then output, the two write tiers, and a sliver of fresh input.
    private static func bucket(_ id: String, total: Double, modelTokens: Bool = true) -> PacerChartBucket {
        let cost = CostComponents(
            input: total * 0.012, output: total * 0.21, cacheRead: total * 0.58,
            cacheWrite5m: total * 0.118, cacheWrite1h: total * 0.08)
        let reads: Int64 = Int64(total * 1_900_000)
        let tokens = TokenBreakdown(
            inputTokens: Int64(total * 2_400), outputTokens: Int64(total * 16_000),
            cacheReadTokens: reads, cacheCreation5mTokens: Int64(total * 40_000),
            cacheCreation1hTokens: Int64(total * 14_000))
        let models: [String: Double] = [
            "claude-opus-4-7": total * 0.81,
            "claude-sonnet-4-5-20250929": total * 0.15,
            "claude-haiku-4-5-20251001": total * 0.04,
        ]
        let all: Double = Double(tokens.all)
        let perModel: [String: Int64] = [
            "claude-opus-4-7": Int64(all * 0.62),
            "claude-sonnet-4-5-20250929": Int64(all * 0.30),
            "claude-haiku-4-5-20251001": Int64(all * 0.08),
        ]
        let breakdown = CostBreakdown(cost: cost, tokens: tokens)
        return PacerChartBucket(
            id: id, breakdown: breakdown,
            topModels: PacerChartBucket.topModels(
                models, tokens: modelTokens ? perModel : nil, of: breakdown.total))
    }

    private static func days(_ n: Int, endingMonth: Int = 10, endingDay: Int = 21) -> [PacerChartBucket] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let df = DateFormatter()
        df.calendar = cal
        df.timeZone = cal.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let end: Date = cal.date(from: DateComponents(year: 2026, month: endingMonth, day: endingDay)) ?? Date()
        return (0..<n).map { i -> PacerChartBucket in
            let date: Date = cal.date(byAdding: .day, value: i - n + 1, to: end) ?? end
            let total: Double = 8 + 70 * wobble(i, 0.4) * wobble(i, 2.1)
            return bucket(df.string(from: date), total: total)
        }
    }

    private static func hours() -> [PacerChartBucket] {
        PacerChartBucket.allHourKeys.enumerated().map { i, key -> PacerChartBucket in
            // Quiet overnight, busy afternoon, nothing after 18:00 yet.
            let active: Bool = i >= 8 && i <= 18
            let total: Double = active ? 0.4 + 6 * wobble(i, 1.2) : 0
            return active ? bucket(key, total: total) : PacerChartBucket(id: key, breakdown: .zero)
        }
    }

    private static func months() -> [PacerChartBucket] {
        (0..<12).map { i -> PacerChartBucket in
            let year: Int = i < 2 ? 2025 : 2026
            let month: Int = i < 2 ? 11 + i : i - 1
            let total: Double = 120 + 900 * wobble(i, 0.9)
            return bucket(String(format: "%04d-%02d", year, month), total: total)
        }
    }

    // MARK: Rendering

    private func render(_ view: some View, width: CGFloat, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let framed = view
                .frame(width: width)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var image: CGImage?
            appearance?.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            let cg = try #require(image)
            let rep = NSBitmapImageRep(cgImage: cg)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let url = outputDir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try png.write(to: url)
        }
    }

    private func card(_ title: String, _ chart: some View) -> some View {
        PacerCard(title, trailing: {
            Text("total $1.2k").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }) { chart }
    }

    @Test func thirtyDays() throws {
        let buckets: [PacerChartBucket] = Self.days(30)
        try render(card("Last 30 days", PacerStackedPartChart(buckets, kind: .day)), width: 760, name: "days-30")
    }

    @Test func thirtyDaysHovered() throws {
        let buckets: [PacerChartBucket] = Self.days(30)
        let left = PacerStackedPartChart(buckets, kind: .day, hovering: buckets[6].id)
        try render(card("Last 30 days", left), width: 760, name: "days-30-hover-left")
        let right = PacerStackedPartChart(buckets, kind: .day, hovering: buckets[26].id)
        try render(card("Last 30 days", right), width: 760, name: "days-30-hover-right")
    }

    @Test func hours() throws {
        let buckets: [PacerChartBucket] = Self.hours()
        let chart = PacerStackedPartChart(buckets, kind: .hour, annotating: 1)
        try render(card("Today by hour", chart), width: 760, name: "hours-24")
        let hovered = PacerStackedPartChart(buckets, kind: .hour, annotating: 1, hovering: "14")
        try render(card("Today by hour", hovered), width: 760, name: "hours-24-hover")
    }

    @Test func months() throws {
        let buckets: [PacerChartBucket] = Self.months()
        let chart = PacerStackedPartChart(buckets, kind: .month, annotating: 12)
        try render(card("Last 12 months", chart), width: 760, name: "months-12")
        let hovered = PacerStackedPartChart(buckets, kind: .month, annotating: 12, hovering: buckets[9].id)
        try render(card("Last 12 months", hovered), width: 760, name: "months-12-hover")
    }

    @Test func sparseTwoDays() throws {
        let buckets: [PacerChartBucket] = Self.days(2)
        let chart = PacerStackedPartChart(buckets, kind: .day, hovering: buckets[0].id)
        try render(card("Last 30 days", chart), width: 760, name: "days-2-sparse-hover")
    }

    @Test func narrowModalChart() throws {
        let buckets: [PacerChartBucket] = Self.days(90, endingDay: 21)
        let chart = PacerStackedPartChart(buckets, kind: .day, hovering: buckets[45].id)
        try render(card("Daily activity", chart), width: 600, name: "days-90-narrow-hover")
    }

    /// The dashboard's merged card, as `DailyCostChartCard.body` lays it out:
    /// the 30-day chart, then the real month section. `monthDays` of the
    /// buckets are this month's; a month with none is the 1st before any use.
    private func thirtyDayCard(
        _ buckets: [PacerChartBucket], monthDays: Int, name: String, daysLeft: Int,
        projection: PacerMonthSummary.Projection
    ) -> some View {
        let month: [PacerChartBucket] = Array(buckets.suffix(monthDays))
        let breakdown: CostBreakdown = month.reduce(CostBreakdown.zero) { $0 + $1.breakdown }
        let total: Double = buckets.reduce(0) { $0 + $1.total }
        let model = PacerMonthSummary.Model(
            name: name, daysLeft: daysLeft, breakdown: breakdown,
            activeDays: month.count, projection: projection)
        return PacerCard("Last 30 days", trailing: {
            Text("total \(pacerCost(total))")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 16) {
                PacerStackedPartChart(buckets, kind: .day)
                Divider()
                PacerMonthSummary(model)
            }
        }
    }

    /// Mid-month: the 22nd, every tile and the spent → projected bar.
    @Test func thirtyDaysAndThisMonth() throws {
        let buckets: [PacerChartBucket] = Self.days(30, endingDay: 22)
        let spent: Double = buckets.suffix(22).reduce(0) { $0 + $1.total }
        let projected: Double = spent / 22 * 31
        let card = thirtyDayCard(
            buckets, monthDays: 22, name: "October", daysLeft: 9,
            projection: .estimate(usd: projected, label: "≈\(pacerCost(projected))", help: ""))
        try render(card, width: 860, name: "dashboard-30-days-and-month")
    }

    /// The 1st: the month is today, every tile still drawn; the engine has
    /// too little of the month to project, so there is no bar yet.
    @Test func thirtyDaysAndTheFirst() throws {
        let buckets: [PacerChartBucket] = Self.days(30, endingMonth: 11, endingDay: 1)
        let card = thirtyDayCard(
            buckets, monthDays: 1, name: "November", daysLeft: 29,
            projection: .unavailable(help: "Not enough of this month yet to project"))
        try render(card, width: 860, name: "dashboard-30-days-and-the-1st")
        // Just past midnight on the 1st, before any use: zeros, not a blank.
        let before: [PacerChartBucket] = Self.days(30, endingDay: 31)
        let empty = thirtyDayCard(
            before, monthDays: 0, name: "November", daysLeft: 29, projection: .pending)
        try render(empty, width: 860, name: "dashboard-30-days-and-the-1st-no-use")
    }

    @Test func hoverCardAlone() throws {
        let b: PacerChartBucket = Self.bucket("2026-10-21", total: 42.37)
        let axis = PacerChartXAxis(kind: .day, ids: [b.id])
        let card = PacerCostHoverCard(title: axis.title(b.id), breakdown: b.breakdown, topModels: b.topModels)
        try render(card, width: PacerCostHoverCard.idealWidth, name: "hover-card")
        let bare = PacerCostHoverCard(title: "2 PM", breakdown: b.breakdown)
        try render(bare, width: PacerCostHoverCard.idealWidth, name: "hover-card-no-models")
        // Project detail's chart: per-model costs, no per-model tokens.
        let p: PacerChartBucket = Self.bucket("2026-10-21", total: 42.37, modelTokens: false)
        let project = PacerCostHoverCard(title: axis.title(p.id), breakdown: p.breakdown, topModels: p.topModels)
        try render(project, width: PacerCostHoverCard.idealWidth, name: "hover-card-project")
        // A big month: the widest numbers each column has to hold.
        let big: PacerChartBucket = Self.bucket("2026-09", total: 12_604)
        let month = PacerCostHoverCard(title: "September 2026", breakdown: big.breakdown, topModels: big.topModels)
        try render(month, width: PacerCostHoverCard.idealWidth, name: "hover-card-month")
    }
}
