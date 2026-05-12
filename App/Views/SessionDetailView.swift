import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Per-session drill-down. Reachable from `ProjectDetailView`'s
/// sessions table (and from `DayDetailView`'s sessions card) via the
/// unified modal navigation — pushed onto the parent NavigationStack
/// rather than opening as a nested modal. The native back button in
/// the navigation chrome returns the user to wherever they came from;
/// Esc/Cmd+W dismisses the whole modal.
struct SessionDetailView: View {
    /// Session identifier. Passed instead of the full SessionInfo so
    /// the view can sit in a `NavigationStack` path (which requires
    /// `Hashable` payloads) — the SessionInfo is fetched here via
    /// `@Query` keyed on this id.
    let sessionId: String
    /// Display name of the project this session belongs to. Plumbed
    /// from the parent so we don't have to re-derive it from the
    /// session's `projectPath` at this layer.
    let projectDisplayName: String

    @Query private var sessions: [SessionInfo]
    @State private var transcriptURL: URL?

    init(sessionId: String, projectDisplayName: String) {
        self.sessionId = sessionId
        self.projectDisplayName = projectDisplayName
        let id = sessionId
        _sessions = Query(
            filter: #Predicate<SessionInfo> { $0.sessionId == id }
        )
    }

    /// The looked-up SessionInfo, or nil while SwiftData hasn't
    /// hydrated the query yet (and the very-rare case where the
    /// session has been deleted since the modal opened).
    private var session: SessionInfo? { sessions.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                if let session {
                    summaryCard(for: session)
                    tokensCard(for: session)
                    metadataCard(for: session)
                } else {
                    missingState
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 460, idealHeight: 560)
        .navigationTitle(navigationTitleText)
        .navigationSubtitle(navigationSubtitleText)
        .task(id: sessionId) {
            // Probe the transcript path on disk so we can offer
            // Reveal/Open buttons without paying the read cost the
            // prior first-prompt resolver did. ~3 dir checks worst
            // case; bounded.
            transcriptURL = await Self.transcriptURL(for: sessionId)
        }
    }

    /// Navigation-bar title — model name for the session, or
    /// "Session" while @Query hasn't hydrated yet (and the very-rare
    /// case where the session vanished after the modal opened).
    private var navigationTitleText: String {
        if let session { return pacerShortModel(session.topModel) }
        return "Session"
    }

    /// Navigation-bar subtitle — short session id · project name.
    /// Mirrors the previous monospaced id line so users can still
    /// pick the session out of a stack visually.
    private var navigationSubtitleText: String {
        let shortId = String(sessionId.prefix(13))
        return "\(shortId) · \(projectDisplayName)"
    }

    private var missingState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Session not found")
                .font(.headline)
            Text(sessionId)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Summary

    @ViewBuilder
    private func summaryCard(for session: SessionInfo) -> some View {
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
                MetricTile(value: Self.durationLabel(for: session), label: "duration", size: .compact)
            }
        }
    }

    /// `firstSeen → lastSeen`. Compact ("3h 12m"); hour granularity for
    /// long-running sessions, second granularity for sub-minute hits so
    /// "0m" is never the answer.
    private static func durationLabel(for session: SessionInfo) -> String {
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

    @ViewBuilder
    private func tokensCard(for session: SessionInfo) -> some View {
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

    @ViewBuilder
    private func metadataCard(for session: SessionInfo) -> some View {
        // Transcript actions live in the card header rather than the
        // sheet toolbar — macOS SwiftUI accumulates `.toolbar` items
        // across every view in a NavigationStack, so a per-view
        // toolbar would persist into deeper destinations. Keeping
        // these inline scopes them to this view.
        PacerCard("Details", trailing: {
            if let url = transcriptURL {
                HStack(spacing: 6) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal transcript", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 11))
                            .labelStyle(.iconOnly)
                    }
                    .controlSize(.small)
                    .help("Reveal the session's JSONL transcript in Finder")

                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open JSONL", systemImage: "doc.plaintext")
                            .font(.system(size: 11))
                            .labelStyle(.iconOnly)
                    }
                    .controlSize(.small)
                    .help("Open the session's JSONL transcript")
                }
            }
        }) {
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
