import WidgetKit
import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "What am I burning right now" widget. Pulls the most-recent
/// `SessionInfo` (sorted desc by lastSeenAt) and surfaces project name,
/// cumulative tokens/cost, and top model. The other widgets are
/// aggregate views; this one is the real-time pulse you'd want on a
/// glanceable surface while actively coding.
///
/// Activity bands (for the colored leading dot + label):
///   - active : last sample ≤ 5 min ago    (green)
///   - recent : last sample ≤ 60 min ago   (yellow)
///   - idle   : older                      (secondary)

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
    case active
    case recent
    case idle

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
                projectDisplayName: "Pacer",
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
            let container = try PacerStore.sharedModelContainer()
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
                    projectDisplayName: pacerShortPath(s.projectPath),
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
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            if let s = entry.session {
                Spacer(minLength: 6)
                // Project name as the second-tier hero — distinctive
                // info even when totals are quiet.
                Text(s.projectDisplayName)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pacerCost(s.costUSD))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("\(pacerTokens(s.totalTokens)) tokens")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                smallFooter(for: s)
            } else {
                Spacer(minLength: 6)
                WidgetEmptyState(message: "No Claude Code activity yet.")
            }
        }
        .padding(WidgetStyle.smallPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleBar
            if let s = entry.session {
                Text(s.projectDisplayName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    statColumn(
                        value: pacerCost(s.costUSD),
                        label: s.topModel.isEmpty ? "session" : pacerShortModel(s.topModel)
                    )
                    Divider().frame(height: 30)
                    statColumn(
                        value: pacerTokens(s.totalTokens),
                        label: "tokens"
                    )
                }
                Spacer(minLength: 0)
                mediumFooter(for: s)
            } else {
                WidgetEmptyState(message: "No Claude Code activity yet.")
            }
        }
        .padding(WidgetStyle.mediumPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var titleBar: some View {
        let activity = entry.session.map { LiveSessionActivity.from(lastSeen: $0.lastSeenAt) }
        WidgetTitleBar(
            title: "SESSION",
            dotColor: activity?.color
        ) {
            if let activity {
                Text(activity.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func smallFooter(for s: LiveSessionEntry.SessionView) -> some View {
        let activity = LiveSessionActivity.from(lastSeen: s.lastSeenAt)
        switch activity {
        case .active:
            Text("\(formatDurationShort(s.elapsedSeconds)) elapsed")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        case .recent, .idle:
            Text("seen \(pacerRelative(s.lastSeenAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func mediumFooter(for s: LiveSessionEntry.SessionView) -> some View {
        let activity = LiveSessionActivity.from(lastSeen: s.lastSeenAt)
        HStack(spacing: 8) {
            switch activity {
            case .active:
                Text("\(formatDurationShort(s.elapsedSeconds)) elapsed")
            case .recent, .idle:
                Text("last seen \(pacerRelative(s.lastSeenAt))")
            }
            Spacer()
            // Show the started-at clock time on medium so the user
            // can place the session in their day.
            Text(s.firstSeenAt, style: .time)
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Configuration

struct LiveSessionWidget: Widget {
    let kind: String = WidgetKinds.liveSession

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LiveSessionProvider()) { entry in
            LiveSessionWidgetView(entry: entry)
        }
        .configurationDisplayName("Current session")
        .description("Project, tokens, cost, and freshness for the most-recent Claude Code session.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
