import SwiftUI
import SwiftData
import PacerCore

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Heartbeat.timestamp, order: .reverse) private var heartbeats: [Heartbeat]

    var body: some View {
        VStack(spacing: 16) {
            Text("Pacer — M1 hello world")
                .font(.title)

            HStack(spacing: 24) {
                stat("Total", heartbeats.count)
                stat("From app", heartbeats.lazy.filter { $0.source == "app" }.count)
                stat("From daemon", heartbeats.lazy.filter { $0.source == "daemon" }.count)
            }

            Button("Add heartbeat from app") {
                context.insert(Heartbeat(source: "app"))
                try? context.save()
            }
            .keyboardShortcut(.defaultAction)

            Divider()

            Text("Recent heartbeats")
                .font(.headline)

            List(heartbeats.prefix(20).map { $0 }, id: \.persistentModelID) { hb in
                HStack {
                    Text(hb.source)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80, alignment: .leading)
                    Text(hb.timestamp.formatted(date: .abbreviated, time: .standard))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 480)
    }

    @ViewBuilder
    private func stat(_ label: String, _ value: Int) -> some View {
        VStack {
            Text("\(value)").font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
