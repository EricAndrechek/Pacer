import WidgetKit
import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Compact "what did I spend today" widget. Hero is the cost in USD,
/// sub-line is total tokens (input + output + cache reads). Refreshed
/// every 5 minutes — fast enough that an active session moves the
/// number visibly, slow enough to fit comfortably inside the OS's
/// widget refresh budget.

struct TodayCostEntry: TimelineEntry {
    let date: Date
    let costUSD: Double
    let tokens: Int64
    let modelCount: Int
    let isFresh: Bool
}

struct TodayCostProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayCostEntry {
        TodayCostEntry(date: Date(), costUSD: 12.34, tokens: 1_234_567, modelCount: 2, isFresh: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayCostEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayCostEntry>) -> Void) {
        let entry = currentEntry()
        let nextRefresh = Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> TodayCostEntry {
        do {
            let container = try PacerStore.makeModelContainer()
            let context = ModelContext(container)
            let today = TokenSample.formatDate(Date())
            let descriptor = FetchDescriptor<DailyAggregate>(
                predicate: #Predicate<DailyAggregate> { $0.date == today }
            )
            let rows = try context.fetch(descriptor)
            let cost = rows.reduce(0) { $0 + $1.totalCostUSD }
            let tokens = rows.reduce(Int64(0)) {
                $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens
            }
            return TodayCostEntry(
                date: Date(),
                costUSD: cost,
                tokens: tokens,
                modelCount: rows.count,
                isFresh: true
            )
        } catch {
            return TodayCostEntry(date: Date(), costUSD: 0, tokens: 0, modelCount: 0, isFresh: false)
        }
    }
}

struct TodayCostWidgetView: View {
    var entry: TodayCostEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetTitleBar(title: "TODAY") {
                Text(pacerWeekdayShort(entry.date))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            // Hero cost — bumped from 28pt to 32pt with a tighter
            // line-height so it dominates the small canvas.
            Text(pacerCost(entry.costUSD))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.primary)
            Text("\(pacerTokens(entry.tokens)) tokens")
                .font(.system(.subheadline, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            footer
        }
        .padding(WidgetStyle.smallPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private var footer: some View {
        if !entry.isFresh {
            Text("no data yet")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if entry.modelCount > 0 {
            HStack(spacing: 4) {
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text("\(entry.modelCount) model\(entry.modelCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("nothing logged today")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct TodayCostWidget: Widget {
    let kind: String = "TodayCostWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayCostProvider()) { entry in
            TodayCostWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's Claude Code spend at a glance.")
        .supportedFamilies([.systemSmall])
    }
}
