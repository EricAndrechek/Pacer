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

    @State private var launchAgentStatus: LaunchAgentInstaller.CombinedStatus = .init(
        smAppService: .unknown,
        devLaunchctl: .notLoaded
    )
    @State private var lastActionMessage: String?
    @State private var resourceSnapshot: DaemonResourceProbe.Snapshot = .init()
    /// Drives the resource panel's auto-refresh ticker. Replaced with a
    /// fresh Date on each tick so the @State change re-renders the
    /// section.
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
            refreshResources()
        }
        // Refresh resource snapshot every 5s while this tab is visible.
        // The TimelineView would be more idiomatic but this is debug
        // chrome, not load-bearing UI; a Timer keeps the view simple.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            refreshResources()
        }
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
                Button("Refresh") { refreshResources() }
            }
            Text("Auto-refresh every 5 seconds while this tab is visible.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
            if !ccVersions.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("Claude Code versions seen:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ccVersions.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Distinct, sort-descending list of `TokenSample.ccVersion`
    /// values. Useful when troubleshooting "why does this user have a
    /// weird parsing edge case" — we can see which Claude Code
    /// versions are in their history.
    private var ccVersions: [String] {
        var seen = Set<String>()
        for s in samples {
            if let v = s.ccVersion, !v.isEmpty {
                seen.insert(v)
            }
        }
        return seen.sorted(by: >)
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
            Text("LaunchAgent (PacerDaemon)").font(.headline)

            // Dev launchctl state — typically what's running for daily-
            // driver use (set up by `make install`). Surfacing it here
            // means the UI never shows "notFound" while a daemon is
            // plainly running and writing to the store.
            HStack(spacing: 12) {
                Text("Dev daemon:")
                Text(devDaemonText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(devDaemonColor)
                Spacer()
                Button("Refresh") { refreshStatus() }
            }

            // SMAppService state — production registration path. The
            // Register/Unregister buttons toggle THIS, not the dev
            // launchctl daemon.
            HStack(spacing: 12) {
                Text("SMAppService:")
                Text(launchAgentStatus.smAppService.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(launchAgentStatus.smAppService == .enabled ? .green : .secondary)
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
            Text("Dev daemon is set up by `make install`; SMAppService is the production path. Pacer never auto-registers either.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var devDaemonText: String {
        switch launchAgentStatus.devLaunchctl {
        case .running(let pid):
            return pid.map { "running (PID \($0))" } ?? "running"
        case .loadedNotRunning:
            return "loaded, not running"
        case .notLoaded:
            return "not loaded"
        }
    }

    private var devDaemonColor: Color {
        switch launchAgentStatus.devLaunchctl {
        case .running:           return .green
        case .loadedNotRunning:  return .yellow
        case .notLoaded:         return .secondary
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

    private func refreshResources() {
        let storeURL = (try? PacerStore.storeURL().path) ?? nil
        let walPath = storeURL.map { $0 + "-wal" }
        resourceSnapshot = DaemonResourceProbe.capture(
            storePath: storeURL,
            walPath: walPath
        )
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func refreshStatus() {
        launchAgentStatus = LaunchAgentInstaller.combinedStatus()
    }
}
