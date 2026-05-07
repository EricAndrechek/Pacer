import WidgetKit
import SwiftUI
import SwiftData
import PacerCore

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
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(formatCost(entry.costUSD))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("\(formatTokens(entry.tokens)) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
            if entry.modelCount > 0 {
                Text("\(entry.modelCount) model\(entry.modelCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if !entry.isFresh {
                Text("no data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1000 { return String(format: "$%.0f", usd) }
        if usd >= 100  { return String(format: "$%.0f", usd) }
        if usd >= 10   { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...:  return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:      return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:          return String(format: "%.1fK", n / 1_000)
        default:                return "\(count)"
        }
    }
}

struct TodayCostWidget: Widget {
    let kind: String = "TodayCostWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayCostProvider()) { entry in
            TodayCostWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Pacer cost")
        .description("Today's Claude Code spend so far, with total tokens.")
        .supportedFamilies([.systemSmall])
    }
}
