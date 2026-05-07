import SwiftUI
import SwiftData
import PacerCore

/// Diagnostic view that surfaces raw daemon state — sample counts,
/// `ClaudeCodeMeta` keys, LaunchAgent registration, recent token rows.
/// Useful during development and when troubleshooting "why isn't my
/// data appearing?" questions. Lives behind the Debug tab so it
/// doesn't clutter the dashboard but isn't lost either.
struct DebugView: View {
    // Cap the TokenSample fetch — Debug only renders the 10 most
    // recent + a count, so materializing all 40k rows on every
    // body update wastes the @Query refetch path that runs on every
    // SwiftData save. We separately track the row count via a
    // dedicated @Query that doesn't materialize the rows themselves.
    @Query(DebugView.recentSamplesDescriptor) private var samples: [TokenSample]
    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]
    @Query(sort: \ClaudeCodeMeta.key) private var meta: [ClaudeCodeMeta]
    @Query(sort: \RateLimitSample.sampledAt, order: .reverse) private var rateLimitSamples: [RateLimitSample]
    /// Per-session rollup. Used here for diagnostics — distinct
    /// ccVersions seen across sessions, plus the total session count.
    /// Way smaller than the underlying TokenSample table, so iterating
    /// in body is fine.
    @Query private var sessions: [SessionInfo]
    /// `TokenSample` count via a no-fetch descriptor — `fetchCount`
    /// avoids materializing rows. Refreshed via the recent-samples
    /// query subscription, which fires whenever new tokens land.
    @State private var totalSampleCount: Int = 0
    @Environment(\.modelContext) private var modelContext

    private static let recentSamplesDescriptor: FetchDescriptor<TokenSample> = {
        var d = FetchDescriptor<TokenSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 50
        return d
    }()

    @State private var loginItemStatus: LoginItemController.Status = .unknown
    @State private var lastActionMessage: String?
    /// Replaced on each timer tick so the resource panel re-renders
    /// even when the underlying meta row's value hasn't changed (the
    /// "age since heartbeat" string ticks forward without a new write).
    @State private var resourceTick = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Debug")
                    .font(.title)

                resourceSection
                Divider()
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
        .onAppear {
            refreshStatus()
            refreshSampleCount()
        }
        // Tick once a second so the "heartbeat age" string updates
        // even when the daemon isn't writing new values. The actual
        // PID/CPU/RSS numbers come from the @Query<ClaudeCodeMeta>
        // subscription, which fires reactively when the daemon writes.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            resourceTick = now
        }
        // Refresh the row count whenever the recent-samples query
        // fires (cheap proxy for "data updated"). `fetchCount` is a
        // count-only SQL query, so this stays sub-ms even on 40k rows.
        .onChange(of: samples.count) { _, _ in
            refreshSampleCount()
        }
    }

    private var resourceSnapshot: DaemonResourceProbe.Snapshot {
        let storeURL = (try? PacerStore.storeURL().path) ?? nil
        let walPath = storeURL.map { $0 + "-wal" }
        return DaemonResourceProbe.snapshot(
            metaRows: meta,
            storePath: storeURL,
            walPath: walPath,
            now: resourceTick
        )
    }

    private var resourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daemon resources").font(.headline)
            HStack(spacing: 24) {
                stat("PID", resourceSnapshot.pid.map(String.init) ?? "—")
                stat("CPU", resourceSnapshot.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                stat("RSS", resourceSnapshot.rssBytes.map(formatBytes) ?? "—")
                stat("Store", resourceSnapshot.storeSizeBytes.map(formatBytes) ?? "—")
                stat("WAL", resourceSnapshot.walSizeBytes.map(formatBytes) ?? "—")
                Spacer()
            }
            heartbeatLine
        }
    }

    @ViewBuilder
    private var heartbeatLine: some View {
        let snap = resourceSnapshot
        if let age = snap.heartbeatAgeSeconds {
            let isFresh = age <= DaemonResourceProbe.stalenessThreshold
            HStack(spacing: 6) {
                Circle()
                    .fill(isFresh ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(isFresh
                     ? "Daemon heartbeat \(formatAge(age)) ago — values self-reported, no process inspection."
                     : "No daemon heartbeat for \(formatAge(age)). Last seen \(formatDate(snap.heartbeatAt ?? Date())).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("Awaiting first daemon heartbeat…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func formatAge(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3_600 { return String(format: "%.0fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3_600)
    }

    // MARK: - Sections

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage").font(.headline)
            HStack(spacing: 24) {
                stat("TokenSamples", totalSampleCount)
                stat("DailyAggregates", aggregates.count)
                stat("Days covered", distinctDates)
                stat("Models seen", distinctModels)
                stat("Sessions", sessions.count)
                stat("RateLimitSamples", rateLimitSamples.count)
            }
            if !distinctCCVersions.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("Claude Code versions seen:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(distinctCCVersions.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Distinct dates seen, derived from the precomputed daily
    /// aggregate rows. Sub-ms — DailyAggregate is a small table.
    private var distinctDates: Int {
        var set = Set<String>()
        for r in aggregates { set.insert(r.date) }
        return set.count
    }

    /// Distinct models seen across all daily aggregates.
    private var distinctModels: Int {
        var set = Set<String>()
        for r in aggregates { set.insert(r.model) }
        return set.count
    }

    /// Distinct ccVersion strings observed across SessionInfo rows.
    /// Sessions are 1-2 orders of magnitude smaller than TokenSamples,
    /// and we only need the version field which SessionInfo carries.
    private var distinctCCVersions: [String] {
        var set = Set<String>()
        for s in sessions {
            if let v = s.ccVersion, !v.isEmpty { set.insert(v) }
        }
        return set.sorted(by: >)
    }

    /// `TokenSample` row count via `fetchCount` — runs as a SQL
    /// COUNT(*) without materializing any rows, so it stays sub-ms
    /// even on a 40k-row store.
    private func refreshSampleCount() {
        let count = (try? modelContext.fetchCount(FetchDescriptor<TokenSample>())) ?? 0
        totalSampleCount = count
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Open at Login").font(.headline)

            HStack(spacing: 12) {
                Text("Status:")
                Text(loginItemStatus.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(loginItemStatus == .enabled ? .green : .secondary)
                Spacer()
                Button("Refresh") { refreshStatus() }
            }

            HStack(spacing: 12) {
                Button("Register") {
                    do {
                        try LoginItemController.register()
                        lastActionMessage = "Registered. May require approval in System Settings → Login Items."
                    } catch {
                        lastActionMessage = "Register failed: \(error.localizedDescription)"
                    }
                    refreshStatus()
                }
                Button("Unregister") {
                    Task {
                        do {
                            try await LoginItemController.unregister()
                            lastActionMessage = "Unregistered."
                        } catch {
                            lastActionMessage = "Unregister failed: \(error.localizedDescription)"
                        }
                        refreshStatus()
                    }
                }
                Button("Open System Settings") {
                    LoginItemController.openSystemSettingsApproval()
                }
            }
            if let msg = lastActionMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Pacer registers the *app itself* via SMAppService.mainApp — the agent-style daemon binary was retired. Background collection runs inside the app process; Open at Login starts it without showing a window. Pacer never auto-registers; the user must flip this on explicitly here or in Settings.")
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

    @ViewBuilder
    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 70)
    }

    private func formatBytes(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...: return String(format: "%.1f GB", n / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.0f MB", n / 1_000_000)
        case 1_000...:         return String(format: "%.0f KB", n / 1_000)
        default:               return "\(count) B"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func refreshStatus() {
        loginItemStatus = LoginItemController.currentStatus()
    }
}
