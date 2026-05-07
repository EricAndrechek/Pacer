import SwiftUI
import SwiftData
import PacerCore

/// First-run welcome card. Rendered at the top of the dashboard
/// whenever the SwiftData store has zero `TokenSample` and zero
/// `RateLimitSample` rows — i.e. the daemon has never written
/// anything. The copy explains what's happening and what they can
/// do next.
///
/// Disappears the moment any data lands; we deliberately don't
/// add a "dismiss" action because the goal is to communicate state,
/// not to be persistent UI chrome.
struct WelcomeCard: View {
    @Query(sort: \TokenSample.sampledAt, order: .reverse) private var tokenSamples: [TokenSample]
    @Query(sort: \RateLimitSample.sampledAt, order: .reverse) private var rateLimits: [RateLimitSample]

    init() {
        // Limit each query to a single row — we only need to know
        // whether any rows exist. Avoids materializing thousands of
        // entities for the existence check.
    }

    private var hasAnyData: Bool {
        !tokenSamples.isEmpty || !rateLimits.isEmpty
    }

    var body: some View {
        if hasAnyData {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "speedometer")
                        .font(.title)
                        .foregroundStyle(.tint)
                    Text("Welcome to Pacer")
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                Text("Pacer tracks your Claude Code usage in real time.")
                    .font(.body)
                VStack(alignment: .leading, spacing: 8) {
                    bullet(
                        icon: "magnifyingglass",
                        title: "Reading your history",
                        body: "On first run Pacer scans every JSONL transcript in `~/.claude/projects` so you start with the data you already have."
                    )
                    bullet(
                        icon: "wave.3.right",
                        title: "Live updates",
                        body: "FSEvents wires the dashboard to your active session — new tokens land here within seconds of being written."
                    )
                    bullet(
                        icon: "speedometer",
                        title: "Rate-limit pacing",
                        body: "OAuth polling shows where you sit in the 5-hour and 7-day rate-limit windows, with a pace projection so you can see if you're on track."
                    )
                }
                .padding(.vertical, 4)
                Text("If nothing appears within a minute, check the Debug tab — the daemon may need to be approved in System Settings on first launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func bullet(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
