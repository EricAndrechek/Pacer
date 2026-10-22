import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

/// Renders `PacerSummaryCard` — History's first card and both detail
/// modals' — to PNGs, light and dark, at History's width and a modal's, on
/// a busy 90 days, a sparse week, a two-day-old install, a day and a
/// project. Off by default; set `PACER_RENDER_UI` to an output directory:
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
    private static let heavy = CostBreakdown(
        cost: CostComponents(
            input: 8.12, output: 1_310.4, cacheRead: 12_603.12,
            cacheWrite5m: 1_512.75, cacheWrite1h: 978.3),
        tokens: TokenBreakdown(
            inputTokens: 1_623_000, outputTokens: 52_400_000,
            cacheReadTokens: 21_512_345_678,
            cacheCreation5mTokens: 242_000_000, cacheCreation1hTokens: 97_800_000))

    private static let light = CostBreakdown(
        cost: CostComponents(input: 0.04, output: 18.2, cacheRead: 61.7, cacheWrite5m: 14.9),
        tokens: TokenBreakdown(
            inputTokens: 8_100, outputTokens: 728_000,
            cacheReadTokens: 123_400_000, cacheCreation5mTokens: 2_380_000))

    /// The card's model for a day strip, through the same helpers the
    /// screens call.
    private static func dayModel(
        _ breakdown: CostBreakdown, stats: [PacerSummaryFact],
        sessions: [String: Int], from start: String
    ) -> PacerSummaryModel {
        let trend: [String: Double] = sessions.mapValues(Double.init)
        let a = PeriodActivity.days(active: Set(sessions.keys), trend: trend, from: start, through: today)
        return PacerSummaryModel(
            breakdown: breakdown, stats: stats, activity: a,
            span: pacerActivitySpan(a) { pacerFactDay($0, currentYear: year) },
            trendCaption: "sessions a day",
            axis: pacerDayAxis(a, today: today, currentYear: year),
            cellHelp: pacerActivityCellHelp(a, currentYear: year) { cell in
                sessions[cell.first].map { "\($0) sessions" }
            })
    }

    static func busy90() -> PacerSummaryModel {
        let keys: [String] = PeriodActivity.dayKeys(from: "2026-07-24", through: today)
        var sessions: [String: Int] = [:]
        for (i, k) in keys.enumerated() {
            // A holiday week and a few days off.
            let idle: Bool = (i >= 30 && i <= 35) || i == 12 || i == 61 || i == 75
            if idle { continue }
            let n: Double = 4 + 30 * wobble(i, 0.4) * wobble(i, 2.1)
            sessions[k] = Int(n.rounded())
        }
        return dayModel(heavy, stats: [.init("sessions", "1,284"), .init("projects", "37"), .init("models", "9")],
                        sessions: sessions, from: "2026-07-24")
    }

    /// A week with three days of use, the last one three days ago.
    static func sparseWeek() -> PacerSummaryModel {
        let sessions: [String: Int] = ["2026-10-16": 2, "2026-10-17": 5, "2026-10-19": 3]
        return dayModel(light + light, stats: [.init("sessions", "9"), .init("projects", "3"), .init("models", "2")],
                        sessions: sessions, from: "2026-10-15")
    }

    /// Installed yesterday: Lifetime is two days.
    static func newInstall() -> PacerSummaryModel {
        let sessions: [String: Int] = ["2026-10-21": 3, "2026-10-22": 6]
        return dayModel(light, stats: [.init("sessions", "8"), .init("projects", "2"), .init("models", "1")],
                        sessions: sessions, from: "2026-10-21")
    }

    /// Two years of history, bucketed into weeks.
    static func lifetime() -> PacerSummaryModel {
        let keys: [String] = PeriodActivity.dayKeys(from: "2024-09-02", through: today)
        var sessions: [String: Int] = [:]
        for (i, k) in keys.enumerated() where wobble(i, 0.9) > 0.35 && !(i > 200 && i < 260) {
            let ramp: Double = Double(i) / Double(keys.count)
            sessions[k] = Int((2 + 25 * ramp * wobble(i, 1.7)).rounded())
        }
        return dayModel(heavy, stats: [.init("sessions", "6,812"), .init("projects", "142"), .init("models", "17")],
                        sessions: sessions, from: "2024-09-02")
    }

    static func project30() -> PacerSummaryModel {
        let keys: [String] = PeriodActivity.dayKeys(from: "2026-09-22", through: today)
        var sessions: [String: Int] = [:]
        for (i, k) in keys.enumerated() where wobble(i, 1.1) > 0.28 && i < keys.count - 1 {
            sessions[k] = Int((1 + 5 * wobble(i, 0.7)).rounded())
        }
        return dayModel(heavy, stats: [.init("sessions", "37"), .init("models", "4"), .init("per active day", "$745")],
                        sessions: sessions, from: "2026-09-22")
    }

    static func day() -> PacerSummaryModel {
        let cost: [Int: Double] = [9: 4.2, 10: 11.8, 11: 7.5, 14: 3.1, 15: 16.4, 16: 21.9, 17: 9.3,
                                   21: 6.2, 22: 12.7, 23: 1.8]
        let a = PeriodActivity.hours(active: Set(cost.keys), trend: cost)
        return PacerSummaryModel(
            breakdown: light,
            stats: [.init("sessions", "12"), .init("models", "3"), .init("projects", "4")],
            activity: a,
            span: pacerActivitySpan(a) { pacerHourLabel(Int($0) ?? 0) },
            trendCaption: "cost an hour",
            axis: pacerHourAxis(),
            cellHelp: pacerActivityCellHelp(a, currentYear: year) { cell in
                Int(cell.first).flatMap { cost[$0] }.map(pacerCostExact)
            })
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
            ("busy90", "Last 90 days", Self.busy90()),
            ("sparse7", "Last 7 days", Self.sparseWeek()),
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
        // A day with no rows: the zeros, the empty strip, no breakdown.
        let empty = PacerSummaryModel(
            breakdown: .zero,
            stats: [.init("sessions", "0"), .init("models", "0"), .init("projects", "0")],
            activity: PeriodActivity.hours(active: [], trend: [:]), trendCaption: "cost an hour",
            axis: pacerHourAxis())
        try render(PacerSummaryCard(model: empty), width: 644, name: "day-modal-empty")
    }

    /// The chart hover card, with the cache line's new In / Out beside it.
    @Test func hoverCard() throws {
        let card = PacerCostHoverCard(title: "Thu, Oct 2", breakdown: Self.light)
        try render(card, width: PacerCostHoverCard.idealWidth + 32, name: "hover-card")
    }
}
