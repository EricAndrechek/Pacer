import SwiftUI
import SwiftData
import PacerCore

/// Per-session drill-down. Reachable from `ProjectDetailView`'s
/// sessions table (and from `DayDetailView`'s sessions card). Replaces
/// the prior in-row "session title + transcript icon" inline pattern
/// with a fuller surface that has room for cumulative tokens broken
/// down by tier, the resolved session title (first user prompt),
/// duration, and a transcript-reveal action.
///
/// Shown as a stacked dismissible modal so clicking outside dismisses
/// just this view, leaving the underlying project / day modal intact.
struct SessionDetailView: View {
    let session: SessionInfo
    /// Display name of the project this session belongs to. Plumbed
    /// from the parent so we don't have to re-derive it from
    /// `projectPath` at this layer.
    let projectDisplayName: String

    @Environment(\.dismissModal) private var dismissModal
    @State private var transcriptURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                header
                summaryCard
                tokensCard
                metadataCard
            }
            .padding(24)
        }
        .scrollIndicators(.never)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 460, idealHeight: 560)
        .task(id: session.sessionId) {
            // Probe the transcript path on disk so we can offer
            // Reveal/Open buttons without paying the read cost the
            // prior first-prompt resolver did. ~3 dir checks worst
            // case; bounded.
            transcriptURL = await Self.transcriptURL(for: session.sessionId)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pacerShortModel(session.topModel))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(String(session.sessionId.prefix(13)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(projectDisplayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("Close") { dismissModal() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        PacerCard("Summary") {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                    count: 4
                ),
                alignment: .leading,
                spacing: 12
            ) {
                MetricTile(value: pacerCost(session.cumulativeCostUSD), label: "cost", size: .hero)
                MetricTile(value: pacerTokens(session.totalTokens), label: "tokens")
                MetricTile(value: pacerShortModel(session.topModel), label: "top model", size: .compact)
                MetricTile(value: durationLabel, label: "duration", size: .compact)
            }
        }
    }

    /// `firstSeen → lastSeen`. Compact ("3h 12m"); hour granularity for
    /// long-running sessions, second granularity for sub-minute hits so
    /// "0m" is never the answer.
    private var durationLabel: String {
        let seconds = max(0, session.lastSeenAt.timeIntervalSince(session.firstSeenAt))
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMin = minutes % 60
        if hours < 24 { return remMin == 0 ? "\(hours)h" : "\(hours)h \(remMin)m" }
        let days = hours / 24
        let remHr = hours % 24
        return remHr == 0 ? "\(days)d" : "\(days)d \(remHr)h"
    }

    // MARK: - Tokens

    private var tokensCard: some View {
        PacerCard("Tokens") {
            VStack(alignment: .leading, spacing: 8) {
                tokenRow("Input", session.cumulativeInputTokens, hint: "uncached prompt bytes")
                tokenRow("Output", session.cumulativeOutputTokens, hint: "model response bytes")
                tokenRow("Cache read", session.cumulativeCacheReadTokens, hint: "served from prompt cache")
                tokenRow("Cache write 5m", session.cumulativeCacheCreation5mTokens, hint: "created in 5-minute tier")
                if session.cumulativeCacheCreation1hTokens > 0 {
                    tokenRow("Cache write 1h", session.cumulativeCacheCreation1hTokens, hint: "created in 1-hour tier (priced higher)")
                }
            }
        }
    }

    @ViewBuilder
    private func tokenRow(_ label: String, _ count: Int64, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(pacerTokens(count))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? .primary : .tertiary)
        }
    }

    // MARK: - Metadata

    private var metadataCard: some View {
        PacerCard("Details") {
            VStack(alignment: .leading, spacing: 10) {
                metadataRow(
                    "First seen",
                    value: Self.dateLabel(session.firstSeenAt)
                )
                metadataRow(
                    "Last seen",
                    value: Self.dateLabel(session.lastSeenAt)
                )
                if let v = session.ccVersion, !v.isEmpty {
                    metadataRow("Claude Code", value: v)
                }
                metadataRow("Project path", value: session.projectPath, monospaced: true)
                metadataRow(
                    "Session ID",
                    value: session.sessionId,
                    monospaced: true,
                    selectable: true
                )
                if transcriptURL != nil {
                    Divider().padding(.vertical, 2)
                    HStack(spacing: 8) {
                        Button {
                            if let url = transcriptURL {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        } label: {
                            Label("Reveal transcript", systemImage: "doc.text.magnifyingglass")
                                .font(.system(size: 12))
                        }
                        Button {
                            if let url = transcriptURL {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Open JSONL", systemImage: "doc.plaintext")
                                .font(.system(size: 12))
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataRow(
        _ label: String,
        value: String,
        monospaced: Bool = false,
        selectable: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            let valueView = Text(value)
                .font(monospaced
                      ? .system(size: 11, design: .monospaced)
                      : .system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            if selectable {
                valueView.textSelection(.enabled)
            } else {
                valueView
            }
            Spacer()
        }
    }

    /// Long-form date for the metadata card. Pinned to the user's
    /// timezone so a 23:59 session doesn't read "tomorrow."
    private static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Walk `~/.claude/projects/*` looking for `<sessionId>.jsonl`.
    /// Same approach the prior inline transcript-reveal button used —
    /// a worktree-spawned subagent's session lives under a different
    /// encoded-cwd directory than its parent project.
    private static func transcriptURL(for sessionId: String) async -> URL? {
        await Task.detached {
            let fm = FileManager.default
            let root = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ) else { return nil }
            for dir in dirs {
                let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil as URL?
        }.value
    }
}
