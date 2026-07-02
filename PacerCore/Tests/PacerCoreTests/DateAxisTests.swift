import Foundation
import Testing
import PacerUI

/// Tests for the shared band-date-axis label picker: right-anchored so the
/// newest date is always labeled and the clipping leftmost index is dropped,
/// and span-aware so long ranges switch from day to month labels.
struct DateAxisTests {

    /// `count` consecutive `YYYY-MM-DD` dates ending at `endingYMD`.
    private func consecutiveDates(_ count: Int, endingYMD: String) -> [String] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        df.calendar = Calendar(identifier: .gregorian)
        guard let end = df.date(from: endingYMD) else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var out: [String] = []
        for i in stride(from: count - 1, through: 0, by: -1) {
            if let d = cal.date(byAdding: .day, value: -i, to: end) { out.append(df.string(from: d)) }
        }
        return out
    }

    @Test func bothEdgeBandsAreDropped() {
        let axis = pacerDateAxis(consecutiveDates(30, endingYMD: "2026-06-30"))
        // Neither extreme band is labeled — those are the ones that clip
        // (newest on the right, oldest on the left).
        #expect(!axis.values.contains("2026-06-30"))
        #expect(!axis.values.contains("2026-06-01"))
        #expect(axis.values.count >= 4 && axis.values.count <= 8)
    }

    @Test func dayLabelsDropTheYear() {
        let axis = pacerDateAxis(consecutiveDates(30, endingYMD: "2026-06-30"))
        #expect(axis.label("2026-06-30") == "06-30")
    }

    @Test func longSpansSwitchToMonthLabels() {
        let axis = pacerDateAxis(consecutiveDates(150, endingYMD: "2026-06-30"))
        // Newest month is June; its mark is June's first present day.
        #expect(axis.label(axis.values.last!) == "Jun")
        // No day-form labels leak through at month granularity.
        #expect(!axis.values.contains { axis.label($0).contains("-") })
    }

    @Test func monthLabelsGainYearAcrossABoundary() {
        // Dec 2025 → Feb 2026 spans a year, so month labels carry the year.
        let axis = pacerDateAxis(consecutiveDates(150, endingYMD: "2026-02-28"))
        #expect(axis.values.contains { axis.label($0).contains("’") })
    }

    @Test func degenerateInputs() {
        #expect(pacerDateAxis([]).values.isEmpty)
        #expect(pacerDateAxis(["2026-06-30"]).values == ["2026-06-30"])
    }

    @Test func shortSpanStillGetsSeveralInteriorLabels() {
        let axis = pacerDateAxis(consecutiveDates(7, endingYMD: "2026-06-30"))
        #expect(axis.values.count >= 4)                    // not decimated to 1–2
        #expect(!axis.values.contains("2026-06-30"))       // still no edge bands
        #expect(!axis.values.contains("2026-06-24"))
    }
}
