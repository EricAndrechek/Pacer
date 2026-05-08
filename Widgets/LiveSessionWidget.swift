import WidgetKit
import SwiftUI
import SwiftData
import PacerCore

/// "What am I burning right now" widget. Pulls the most-recent
/// `SessionInfo` (sorted desc by lastSeenAt) and surfaces project name,
/// cumulative tokens/cost, and top model. The other widgets (today
/// summary, gauges, 14-day chart) are aggregate views; this one is the
/// real-time "you're in a session, here's what it cost so far" pulse
/// you'd want on a glanceable surface while actively coding.
///
/// Activity bands (for the colored dot + label):
///   - active : last sample <= 5 min ago
///   - recent : last sample <= 60 min ago
///   - idle   : older
///
/// 5-minute refresh budget matches `TodayCostWidget`. SessionInfo is
/// kept up-to-date every scan cycle by `SessionInfoRecomputer`, so the
/// widget reads precomputed rows — no TokenSample iteration here.

struct LiveSessionEntry: TimelineEntry {
    let date: Date
    let session: SessionView?

    struct SessionView {
        let projectDisplayName: String
        let totalTokens: Int64
        let costUSD: Double
        let topModel: String
        let firstSeenAt: Date
        let lastSeenAt: Date
        var elapsedSeconds: TimeInterval { lastSeenAt.timeIntervalSince(firstSeenAt) }
    }
}

enum LiveSessionActivity {
    case active   // <= 5 min
    case recent   // <= 60 min
    case idle     // older

    static func from(lastSeen: Date, now: Date = Date()) -> LiveSessionActivity {
        let age = now.timeIntervalSince(lastSeen)
        if age <= 300 { return .active }
        if age <= 3600 { return .recent }
        return .idle
    }

    var color: Color {
        switch self {
        case .active: return .green
        case .recent: return .yellow
        case .idle:   return .secondary
        }
    }

    var label: String {
        switch self {
        case .active: return "active"
        case .recent: return "recent"
        case .idle:   return "idle"
        }
    }
}

struct LiveSessionProvider: TimelineProvider {
    func placeholder(in context: Context) -> LiveSessionEntry {
        LiveSessionEntry(
            date: Date(),
            session: .init(
                projectDisplayName: "ccmac",
                totalTokens: 142_300,
                costUSD: 4.12,
                topModel: "sonnet-4-6",
                firstSeenAt: Date().addingTimeInterval(-38 * 60),
                lastSeenAt: Date().addingTimeInterval(-30)
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LiveSessionEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveSessionEntry>) -> Void) {
        let entry = currentEntry()
        let nextRefresh = Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> LiveSessionEntry {
        do {
            let container = try PacerStore.makeModelContainer()
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<SessionInfo>(
                sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            let rows = try context.fetch(descriptor)
            guard let s = rows.first else {
                return LiveSessionEntry(date: Date(), session: nil)
            }
            return LiveSessionEntry(
                date: Date(),
                session: .init(
                    projectDisplayName: shortPath(s.projectPath),
                    totalTokens: s.totalTokens,
                    costUSD: s.cumulativeCostUSD,
                    topModel: s.topModel,
                    firstSeenAt: s.firstSeenAt,
                    lastSeenAt: s.lastSeenAt
                )
            )
        } catch {
            return LiveSessionEntry(date: Date(), session: nil)
        }
    }
}

// MARK: - Views

struct LiveSessionWidgetView: View {
    let entry: LiveSessionEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: small
        default:           medium
        }
    }

    @ViewBuilder
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 4)
            if let s = entry.session {
                Text(formatTokens(s.totalTokens))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(formatCost(s.costUSD))
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                footer(for: s)
            } else {
                emptyState
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let s = entry.session {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatTokens(s.totalTokens))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("tokens")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Divider().frame(height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatCost(s.costUSD))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(s.topModel.isEmpty ? "no model" : shortModel(s.topModel))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                footer(for: s)
            } else {
                emptyState
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            if let s = entry.session {
                let activity = LiveSessionActivity.from(lastSeen: s.lastSeenAt)
                Circle()
                    .fill(activity.color)
                    .frame(width: 6, height: 6)
                Text(s.projectDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(activity.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func footer(for s: LiveSessionEntry.SessionView) -> some View {
        let activity = LiveSessionActivity.from(lastSeen: s.lastSeenAt)
        switch activity {
        case .active:
            Text("\(formatDuration(s.elapsedSeconds)) elapsed")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .recent, .idle:
            Text("last seen \(relative(s.lastSeenAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No Claude Code activity yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: - Formatters

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...:  return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:      return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:          return String(format: "%.1fK", n / 1_000)
        default:                return "\(count)"
        }
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1000 { return String(format: "$%.0f", usd) }
        if usd >= 100  { return String(format: "$%.0f", usd) }
        if usd >= 10   { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// Widget-target redeclarations of two App-target string helpers
// (App views aren't importable into the extension; the bodies are
// trivial so duplicating beats hoisting them into PacerCore for two
// widgets to share).
private func shortPath(_ path: String) -> String {
    if path == ProjectDailyAggregate.unknownProjectPath { return "(unknown)" }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
}

private func shortModel(_ name: String) -> String {
    if let lastSlash = name.lastIndex(of: "/") {
        return String(name[name.index(after: lastSlash)...])
    }
    return name
}

// MARK: - Configuration

struct LiveSessionWidget: Widget {
    let kind: String = "LiveSessionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LiveSessionProvider()) { entry in
            LiveSessionWidgetView(entry: entry)
        }
        .configurationDisplayName("Live session")
        .description("Most-recent Claude Code session: project, tokens, cost, model, freshness.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
