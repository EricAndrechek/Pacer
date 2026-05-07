import SwiftUI
import SwiftData
import PacerCore

/// Diagnostic view that surfaces raw daemon state — sample counts,
/// `ClaudeCodeMeta` keys, LaunchAgent registration, recent token rows.
/// Useful during development and when troubleshooting "why isn't my
/// data appearing?" questions. Lives behind the Debug tab so it
/// doesn't clutter the dashboard but isn't lost either.
struct DebugView: View {
    @Query(sort: \TokenSample.sampledAt, order: .reverse) private var samples: [TokenSample]
    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]
    @Query(sort: \ClaudeCodeMeta.key) private var meta: [ClaudeCodeMeta]
    @Query(sort: \RateLimitSample.sampledAt, order: .reverse) private var rateLimitSamples: [RateLimitSample]

    @State private var launchAgentStatus: LaunchAgentInstaller.Status = .unknown
    @State private var lastActionMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Debug")
                    .font(.title)

                statsSection
                Divider()
                rateLimitsRawSection
                Divider()
                metaSection
                Divider()
                launchAgentSection
                Divider()
                recentSamplesSection
            }
            .padding(24)
        }
        .frame(minWidth: 640, minHeight: 600)
        .onAppear { refreshStatus() }
    }

    // MARK: - Sections

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage").font(.headline)
            HStack(spacing: 24) {
                stat("TokenSamples", samples.count)
                stat("DailyAggregates", aggregates.count)
                stat("Days covered", Set(samples.map(\.date)).count)
                stat("Models seen", Set(samples.map(\.model)).count)
                stat("RateLimitSamples", rateLimitSamples.count)
            }
        }
    }

    private var rateLimitsRawSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rate-limit samples (raw)").font(.headline)
            if rateLimitSamples.isEmpty {
                Text("No rate-limit data yet.")
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
            } else {
                ForEach(rateLimitSamples.prefix(10), id: \.persistentModelID) { s in
                    HStack(alignment: .top) {
                        Text(s.window)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%5.1f%%", s.usedPercentage))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                        Text(s.source)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                            .foregroundStyle(.tertiary)
                        Text(formatDate(s.sampledAt))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daemon state (ClaudeCodeMeta)").font(.headline)
            if meta.isEmpty {
                Text("No meta keys yet — daemon hasn't run.")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
            } else {
                ForEach(meta, id: \.key) { entry in
                    HStack(alignment: .top) {
                        Text(entry.key)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 220, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(entry.value)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var launchAgentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LaunchAgent (PacerDaemon)").font(.headline)
            HStack(spacing: 12) {
                Text("Status:")
                Text(launchAgentStatus.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(launchAgentStatus == .enabled ? .green : .secondary)
                Spacer()
                Button("Refresh") { refreshStatus() }
            }
            HStack(spacing: 12) {
                Button("Register") {
                    do {
                        try LaunchAgentInstaller.register()
                        lastActionMessage = "Registered. May require approval in System Settings."
                    } catch {
                        lastActionMessage = "Register failed: \(error.localizedDescription)"
                    }
                    refreshStatus()
                }
                Button("Unregister") {
                    Task {
                        do {
                            try await LaunchAgentInstaller.unregister()
                            lastActionMessage = "Unregistered."
                        } catch {
                            lastActionMessage = "Unregister failed: \(error.localizedDescription)"
                        }
                        refreshStatus()
                    }
                }
                Button("Open System Settings") {
                    LaunchAgentInstaller.openSystemSettingsApproval()
                }
            }
            if let msg = lastActionMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Pacer never auto-registers. Click Register to opt in.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var recentSamplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent TokenSamples").font(.headline)
            if samples.isEmpty {
                Text("No samples yet — start the daemon (or run with PACER_RUN_ONCE=1).")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(samples.prefix(10), id: \.persistentModelID) { s in
                    HStack(alignment: .top) {
                        Text(s.date)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                        Text(s.model)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 200, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text("in:\(s.inputTokens) out:\(s.outputTokens) cR:\(s.cacheReadTokens) cC5m:\(s.cacheCreation5mTokens) cC1h:\(s.cacheCreation1hTokens)")
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func stat(_ label: String, _ value: Int) -> some View {
        VStack {
            Text("\(value)").font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func refreshStatus() {
        launchAgentStatus = LaunchAgentInstaller.currentStatus()
    }
}
