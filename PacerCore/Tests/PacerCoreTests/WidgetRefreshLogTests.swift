import Foundation
import Testing
@testable import PacerCore

/// The widget extension's record of every timeline macOS granted, and the
/// app's hourly summary of it (#318).
@Suite("Widget refresh log")
struct WidgetRefreshLogTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-refreshes-\(UUID().uuidString).log")
    }

    @Test func aLineRoundTrips() throws {
        let entry = WidgetRefreshLog.Entry(at: Self.now.addingTimeInterval(0.345), event: .timeline,
                                           kind: WidgetKinds.paceGauges, family: "systemMedium",
                                           next: Self.now.addingTimeInterval(300))
        let line = WidgetRefreshLog.line(entry)
        #expect(line.hasSuffix(" timeline PaceGaugesWidget systemMedium next=2026-09-21T14:18:20Z"))
        let back = try #require(WidgetRefreshLog.parse(line))
        #expect(back.event == .timeline)
        #expect(back.kind == WidgetKinds.paceGauges)
        #expect(back.family == "systemMedium")
        #expect(back.next == Self.now.addingTimeInterval(300))
        #expect(abs(back.at.timeIntervalSince(entry.at)) < 0.001)

        let snap = WidgetRefreshLog.Entry(at: Self.now, event: .snapshot, kind: WidgetKinds.todayCost,
                                          family: "systemSmall", next: nil)
        #expect(WidgetRefreshLog.parse(WidgetRefreshLog.line(snap))?.next == nil)
        // A truncated last line, or anything else, is skipped.
        #expect(WidgetRefreshLog.parse("2026-09-21T14:13") == nil)
        #expect(WidgetRefreshLog.parse("") == nil)
        #expect(WidgetRefreshLog.parse("2026-09-21T14:13:20Z grant PaceGaugesWidget systemSmall") == nil)
    }

    @Test func recordAppendsAndReadsBack() {
        let url = Self.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        WidgetRefreshLog.record(.timeline, kind: WidgetKinds.paceChart, family: "systemLarge",
                                next: Self.now.addingTimeInterval(600), at: Self.now, to: url)
        WidgetRefreshLog.record(.snapshot, kind: WidgetKinds.paceChart, family: "systemLarge",
                                next: nil, at: Self.now.addingTimeInterval(1), to: url)
        let entries = WidgetRefreshLog.entries(at: url)
        #expect(entries.map(\.event) == [.timeline, .snapshot])
        // No container, no file: nothing happens and nothing throws.
        WidgetRefreshLog.record(.timeline, kind: "x", family: "y", next: nil, to: nil)
        #expect(WidgetRefreshLog.entries(at: nil).isEmpty)
        // An unwritable path is swallowed too.
        WidgetRefreshLog.record(.timeline, kind: "x", family: "y", next: nil,
                                to: URL(fileURLWithPath: "/nonexistent-dir/widget.log"))
    }

    @Test func pastTheCapTheNewestHalfIsKeptOnALineBoundary() throws {
        let url = Self.tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var i = 0
        while (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                <= WidgetRefreshLog.byteCap - 200 {
            WidgetRefreshLog.record(.timeline, kind: WidgetKinds.liveSession, family: "systemSmall",
                                    next: nil, at: Self.now.addingTimeInterval(Double(i)), to: url)
            i += 1
        }
        let before = WidgetRefreshLog.entries(at: url).count
        for j in 0..<10 {
            WidgetRefreshLog.record(.timeline, kind: WidgetKinds.liveSession, family: "systemSmall",
                                    next: nil, at: Self.now.addingTimeInterval(Double(i + j)), to: url)
        }
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size <= WidgetRefreshLog.byteCap / 2 + 1_200)
        let after = WidgetRefreshLog.entries(at: url)
        // Every line kept is whole, and the newest is the last written.
        #expect(after.count < before)
        #expect(after.last?.at == Self.now.addingTimeInterval(Double(i + 9)))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == after.count)
    }

    @Test func theHourlySummaryCountsGrantsAgainstRequests() {
        func timeline(_ kind: String, minutesAgo: Double) -> WidgetRefreshLog.Entry {
            .init(at: Self.now.addingTimeInterval(-minutesAgo * 60), event: .timeline, kind: kind,
                  family: "systemSmall", next: nil)
        }
        let entries: [WidgetRefreshLog.Entry] = [
            timeline(WidgetKinds.paceGauges, minutesAgo: 5),
            timeline(WidgetKinds.paceGauges, minutesAgo: 25),
            timeline(WidgetKinds.paceGauges, minutesAgo: 59),
            timeline(WidgetKinds.paceChart, minutesAgo: 10),
            timeline(WidgetKinds.paceChart, minutesAgo: 40),
            timeline(WidgetKinds.liveSession, minutesAgo: 30),
            // Older than the hour, inside the day.
            timeline(WidgetKinds.todayCost, minutesAgo: 61),
            timeline(WidgetKinds.paceGauges, minutesAgo: 600),
            // Older than the day.
            timeline(WidgetKinds.paceGauges, minutesAgo: 1500),
            // A snapshot is not a grant.
            .init(at: Self.now.addingTimeInterval(-60), event: .snapshot, kind: WidgetKinds.paceChart,
                  family: "systemSmall", next: nil),
        ]
        let summary = WidgetRefreshLog.summary(entries: entries, requested: 41, now: Self.now)
        #expect(summary.requested == 41)
        #expect(summary.granted == 6)
        #expect(summary.granted24h == 8)
        #expect(summary.text
                == "last hour: requested 41, granted 6 (PaceGauges 3 · PaceChart 2 · LiveSession 1); last 24 h granted 8")
        let quiet = WidgetRefreshLog.summary(entries: [], requested: 0, now: Self.now)
        #expect(quiet.text == "last hour: requested 0, granted 0; last 24 h granted 0")
    }

    @Test func kindsAreNamedWithoutTheirSuffix() {
        #expect(WidgetRefreshLog.shortName(WidgetKinds.liveSession) == "LiveSession")
        #expect(WidgetRefreshLog.shortName("Widget") == "Widget")
        #expect(WidgetRefreshLog.shortName("Custom") == "Custom")
    }
}
