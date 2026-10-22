import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// The shared donut beside a usage table (Today by model, the Projects list):
// it measures what the table is sorted by when that adds up, cost otherwise,
// ranks its wedges largest first whatever the direction, folds a long tail
// into one Other wedge, and maps a hover back to the right wedge.

@Suite("Share donut")
struct ShareDonutTests {

    /// A screen with one column that adds up (sessions) and one that does
    /// not (a date).
    struct Project: PacerUsageExtra, Sendable {
        let sessions: Int
        let lastActive: Date
        func sortKey(forColumn id: String) -> PacerUsageSortKey? {
            switch id {
            case "sessions":   return .number(Double(sessions))
            case "lastActive": return .date(lastActive)
            default:           return nil
            }
        }
        static func shareMetric(forColumn id: String) -> PacerShareMetric? {
            id == "sessions" ? PacerShareMetric(column: id, title: "Sessions") : nil
        }
        func shareValue(forColumn id: String) -> Double? {
            id == "sessions" ? Double(sessions) : nil
        }
    }

    /// Three rows whose order differs by cost, by output tokens and by
    /// sessions, so a donut measuring the wrong column ranks them wrongly.
    static func rows() -> [PacerUsageRow<Project>] {
        [
            PacerUsageRow(id: "a", label: "Alpha", color: .red,
                          tokens: TokenBreakdown(inputTokens: 10, outputTokens: 300),
                          costParts: CostComponents(input: 1, output: 1),
                          extra: Project(sessions: 20, lastActive: Date(timeIntervalSince1970: 3))),
            PacerUsageRow(id: "b", label: "Beta", color: .blue,
                          tokens: TokenBreakdown(inputTokens: 10, outputTokens: 100),
                          costParts: CostComponents(input: 3, output: 3),
                          extra: Project(sessions: 5, lastActive: Date(timeIntervalSince1970: 1))),
            PacerUsageRow(id: "c", label: "Gamma", color: .green,
                          tokens: TokenBreakdown(inputTokens: 10, outputTokens: 200),
                          costParts: CostComponents(input: 2, output: 2),
                          extra: Project(sessions: 10, lastActive: Date(timeIntervalSince1970: 2))),
        ]
    }

    @Test("it measures the sorted column, largest first, whichever way the table runs",
          arguments: [true, false])
    func followsTheSort(descending: Bool) {
        let byCost = PacerShareDonutData(rows: Self.rows(), sort: PacerUsageSort(.cost, descending: descending))
        #expect(byCost.metric == .cost)
        #expect(byCost.slices.map(\.id) == ["b", "c", "a"])
        #expect(byCost.total == 12)

        let byOutput = PacerShareDonutData(rows: Self.rows(), sort: PacerUsageSort(.output, descending: descending))
        #expect(byOutput.metric.column == UsageColumn.output.rawValue)
        #expect(byOutput.metric.title == "Output")
        #expect(byOutput.slices.map(\.id) == ["a", "c", "b"])
        #expect(byOutput.total == 600)

        let bySessions = PacerShareDonutData(rows: Self.rows(), sort: PacerUsageSort(column: "sessions", descending: descending))
        #expect(bySessions.metric.title == "Sessions")
        #expect(bySessions.slices.map(\.id) == ["a", "c", "b"])
        #expect(bySessions.slices.map(\.value) == [20, 10, 5])
    }

    @Test("Total is called Tokens in the donut, and counts every part")
    func totalIsTokens() {
        let data = PacerShareDonutData(rows: Self.rows(), sort: PacerUsageSort(.tokens, descending: true))
        #expect(data.metric.title == "Tokens")
        #expect(data.slices.map(\.value) == [310, 210, 110])
    }

    @Test("a column that does not add up leaves the donut on cost",
          arguments: ["name", "outShare", "hitRate", "writeShare", "mix", "lastActive", "retired"])
    func fallsBackToCost(column: String) {
        let data = PacerShareDonutData(rows: Self.rows(), sort: PacerUsageSort(column: column, descending: true))
        #expect(data.metric == .cost)
        #expect(data.slices.map(\.id) == ["b", "c", "a"])
    }

    @Test("every standard column either adds up or falls back")
    func everyColumnDecided() {
        let additive: [UsageColumn] = UsageColumn.allCases.filter { $0.shareMetric != nil }
        #expect(additive == [.input, .output, .cacheRead, .cacheWrite, .cacheWrite5m, .cacheWrite1h,
                             .tokens, .cost])
    }

    @Test("wedges carry the rows' labels and colours; a row with nothing has no wedge")
    func slicesFromRows() {
        var rows = Self.rows()
        rows.append(PacerUsageRow(id: "z", label: "Zero", color: .gray, tokens: .zero,
                                  costParts: .zero,
                                  extra: Project(sessions: 0, lastActive: .distantPast)))
        let data = PacerShareDonutData(rows: rows, sort: .costDescending)
        #expect(data.slices.map(\.label) == ["Beta", "Gamma", "Alpha"])
        #expect(data.slices.map(\.color) == [.blue, .green, .red])
        #expect(data.slices.allSatisfy { $0.rows == 1 })
    }

    static func manyRows(_ n: Int) -> [PacerUsageRow<PacerUsageNoExtra>] {
        (0..<n).map { i in
            PacerUsageRow(id: "p\(i)", label: "P\(i)", color: .orange, tokens: .zero,
                          costParts: CostComponents(input: Double(n - i)))
        }
    }

    @Test("the tail past the cap folds into one Other wedge, so the shares are of everything")
    func foldsTheTail() throws {
        let data = PacerShareDonutData(rows: Self.manyRows(9), sort: .costDescending, maxSlices: 5)
        #expect(data.slices.count == 6)
        #expect(data.slices.prefix(5).map(\.id) == ["p0", "p1", "p2", "p3", "p4"])
        let other = try #require(data.slices.last)
        #expect(other.id == PacerShareDonutData.otherID)
        #expect(other.label == "4 others")
        #expect(other.rows == 4)
        // 4 + 3 + 2 + 1 of 45.
        #expect(other.value == 10)
        #expect(data.total == 45)
        #expect(abs(data.share(of: other) - 10.0 / 45.0) < 1e-12)
    }

    @Test("one row past the cap keeps its own wedge rather than an Other of one")
    func noOtherOfOne() {
        let data = PacerShareDonutData(rows: Self.manyRows(6), sort: .costDescending, maxSlices: 5)
        #expect(data.slices.count == 6)
        #expect(!data.slices.contains { $0.id == PacerShareDonutData.otherID })
    }

    @Test("a hover angle names the wedge it falls in, edges included")
    func hoverLookup() {
        // Wedges 6 (b), 4 (c), 2 (a): ends at 6, 10, 12.
        let data = PacerShareDonutData(rows: Self.rows(), sort: .costDescending)
        #expect(data.slice(at: nil) == nil)
        #expect(data.slice(at: 0)?.id == "b")
        #expect(data.slice(at: 6)?.id == "b")
        #expect(data.slice(at: 6.01)?.id == "c")
        #expect(data.slice(at: 10)?.id == "c")
        #expect(data.slice(at: 11)?.id == "a")
        // Past the end (rounding at the seam) is the last wedge.
        #expect(data.slice(at: 12.5)?.id == "a")
        let b = data.slices[0]
        #expect(abs(data.share(of: b) - 0.5) < 1e-12)
    }

    @Test("an empty table draws an empty ring, and says so")
    func empty() {
        let data = PacerShareDonutData(rows: [PacerUsageRow<PacerUsageNoExtra>](), sort: .costDescending)
        #expect(data.slices.isEmpty)
        #expect(data.total == 0)
        #expect(data.slice(at: 1) == nil)
        #expect(data.spokenSummary == "no data yet")
    }
}
