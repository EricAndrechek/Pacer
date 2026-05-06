import WidgetKit
import SwiftUI
import SwiftData
import PacerCore

struct HeartbeatEntry: TimelineEntry {
    let date: Date
    let totalCount: Int
    let appCount: Int
    let daemonCount: Int
}

struct HeartbeatProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeartbeatEntry {
        HeartbeatEntry(date: Date(), totalCount: 0, appCount: 0, daemonCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (HeartbeatEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeartbeatEntry>) -> Void) {
        let entry = currentEntry()
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
        completion(timeline)
    }

    private func currentEntry() -> HeartbeatEntry {
        do {
            let container = try PacerStore.makeModelContainer()
            let context = ModelContext(container)
            let total = try context.fetchCount(FetchDescriptor<Heartbeat>())
            let app = try context.fetchCount(FetchDescriptor<Heartbeat>(predicate: #Predicate { $0.source == "app" }))
            let daemon = try context.fetchCount(FetchDescriptor<Heartbeat>(predicate: #Predicate { $0.source == "daemon" }))
            return HeartbeatEntry(date: Date(), totalCount: total, appCount: app, daemonCount: daemon)
        } catch {
            return HeartbeatEntry(date: Date(), totalCount: -1, appCount: 0, daemonCount: 0)
        }
    }
}

struct PacerHeartbeatWidgetEntryView: View {
    var entry: HeartbeatEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pacer")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(entry.totalCount)")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            HStack(spacing: 8) {
                Label("\(entry.appCount)", systemImage: "macwindow")
                Label("\(entry.daemonCount)", systemImage: "gearshape.2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct PacerHeartbeatWidget: Widget {
    let kind: String = "PacerHeartbeatWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HeartbeatProvider()) { entry in
            PacerHeartbeatWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pacer heartbeats")
        .description("M1 hello-world — count of heartbeats in the shared store.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
