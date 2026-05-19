import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "Return on Investment" — join Claude Code sessions to git commits
/// per project. Answers questions the cost-only views can't: how much
/// did each commit cost? Was today's spend producing visible work?
///
/// This view is gated on the user actually having git repos for the
/// projects Pacer has seen. For projects where Pacer's path is a
/// descendant of a git root, we walk up to the root (matching
/// `ProjectGitRootScanner.findGitRoot`); for projects with no `.git`
/// in the ancestor chain, we mark them as "no git" and skip the
/// commit fetch.
struct ROIView: View {
    /// Sessions in the lookback window. Filtered by `firstSeenAt` so
    /// the index does the work. We also group by `projectPath`
    /// in-view — there's no per-project SwiftData rollup yet because
    /// ROI doesn't fit the existing rollup template (it depends on
    /// git, not just SwiftData state).
    @Query private var sessions: [SessionInfo]

    @State private var rois: [ROIComputer.ProjectROI] = []
    @State private var skippedProjects: [String] = []
    @State private var loading = false
    @State private var lastComputedAt: Date?
    @AppStorage("pacer.roi.windowDays", store: PacerSettings.store)
    private var windowDaysRaw: Int = 30

    init() {
        // 90-day predicate window — the picker only goes up to 90.
        // We refilter in-memory to the user's chosen window before
        // running git, so a 30-day default doesn't materialize older
        // rows.
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -90, to: Date()
        ) ?? Date()
        _sessions = Query(
            filter: #Predicate<SessionInfo> { $0.firstSeenAt >= cutoff },
            sort: \.firstSeenAt
        )
    }

    private var window: WindowOption {
        WindowOption(days: windowDaysRaw)
    }

    var body: some View {
        PageScaffold(
            "ROI",
            subtitle: "Cost per git commit, joined per project."
        ) {
            controlsCard
            if loading && rois.isEmpty {
                loadingCard
            } else if rois.isEmpty {
                emptyStateCard
            } else {
                summaryCard
                tableCard
            }
            if !skippedProjects.isEmpty {
                skippedCard
            }
        }
        .task(id: windowDaysRaw) { await refresh() }
    }

    // MARK: - Cards

    private var controlsCard: some View {
        PacerCard("Window") {
            HStack(spacing: 16) {
                Picker("Window", selection: $windowDaysRaw) {
                    ForEach(WindowOption.allCases, id: \.self) { opt in
                        Text(opt.label).tag(opt.days)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
                if loading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(loading)
                if let at = lastComputedAt {
                    Text("updated \(pacerRelative(at))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var loadingCard: some View {
        PacerCard("Computing") {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Reading git log for each project. First load can take a few seconds on large repos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyStateCard: some View {
        PacerCard("No ROI data yet") {
            Text("Pacer joins git commits to Claude Code sessions, but none of the projects in the last \(window.days) days had any commits in their git history. Try a longer window or run `git log` on the projects yourself to confirm they're git repos.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryCard: some View {
        let totalCost = rois.reduce(0) { $0 + $1.attributedCostUSD }
        let totalCommits = rois.reduce(0) { $0 + $1.commitCount }
        let totalLines = rois.reduce(0) { $0 + $1.linesAdded + $1.linesRemoved }
        let unattributed = rois.reduce(0) { $0 + $1.unattributedCommits }

        return PacerCard("Summary · \(window.label)") {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                    count: 4
                ),
                alignment: .leading,
                spacing: 12
            ) {
                MetricTile(
                    value: "\(totalCommits)",
                    label: "commits",
                    hint: unattributed > 0 ? "\(unattributed) unattributed" : nil
                )
                MetricTile(
                    value: pacerCost(totalCost),
                    label: "attributed cost",
                    hint: "across \(rois.count) project\(rois.count == 1 ? "" : "s")"
                )
                MetricTile(
                    value: totalCommits > 0 && totalCost > 0
                        ? pacerCost(totalCost / Double(totalCommits))
                        : "—",
                    label: "$ / commit",
                    hint: "avg across all projects"
                )
                MetricTile(
                    value: totalLines > 0 && totalCost > 0
                        ? pacerCost(totalCost / Double(totalLines))
                        : "—",
                    label: "$ / line",
                    hint: "added + removed"
                )
            }
        }
    }

    private var tableCard: some View {
        PacerCard("Projects") {
            // Plain table — uses a fixed column layout because Table()
            // inside a ScrollView in macOS 15 sometimes refuses to
            // size to content. A simple grid is cheaper and more
            // predictable.
            VStack(spacing: 0) {
                tableHeader
                Divider().opacity(0.5)
                ForEach(rois.sorted(by: { $0.attributedCostUSD > $1.attributedCostUSD }), id: \.projectPath) { row in
                    tableRow(row)
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private var skippedCard: some View {
        PacerCard("Skipped") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Projects without a git repo (or where git couldn't read the history):")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(skippedProjects, id: \.self) { p in
                    Text(p)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Project").frame(maxWidth: .infinity, alignment: .leading)
            Text("Commits").frame(width: 72, alignment: .trailing)
            Text("Lines").frame(width: 96, alignment: .trailing)
            Text("Cost").frame(width: 80, alignment: .trailing)
            Text("$/commit").frame(width: 80, alignment: .trailing)
            Text("$/line").frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func tableRow(_ row: ROIComputer.ProjectROI) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pacerShortPath(row.projectPath))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.unattributedCommits > 0 {
                    Text("\(row.unattributedCommits) commit\(row.unattributedCommits == 1 ? "" : "s") with no matching session")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.commitCount)")
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Text("+\(row.linesAdded)/-\(row.linesRemoved)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(pacerCost(row.attributedCostUSD))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Text(row.costPerCommit.map(pacerCost) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(row.costPerLine.map(pacerCost) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
    }

    // MARK: - Compute

    private func refresh() async {
        loading = true
        defer { loading = false }

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -window.days,
            to: Date()
        ) ?? Date()

        // Extract everything from SwiftData rows on the MainActor
        // BEFORE any cross-task hop — `SessionInfo` is a SwiftData
        // @Model class which Swift 6 doesn't treat as Sendable.
        // `SessionWindow` is a plain Sendable struct so it crosses
        // the boundary cleanly.
        var windowsByProject: [String: [ROIComputer.SessionWindow]] = [:]
        for s in sessions where s.firstSeenAt >= cutoff {
            let w = ROIComputer.SessionWindow(
                sessionId: s.sessionId,
                projectPath: s.projectPath,
                firstSeenAt: s.firstSeenAt,
                lastSeenAt: s.lastSeenAt,
                costUSD: s.cumulativeCostUSD
            )
            windowsByProject[s.projectPath, default: []].append(w)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectPaths = Array(windowsByProject.keys)

        // Read git logs concurrently. Each git invocation is its own
        // subprocess and most of the wait is I/O; bounded concurrency
        // (8 at a time) keeps the spawn rate reasonable while still
        // being noticeably faster than serial on a multi-project
        // install.
        let computed = await withTaskGroup(
            of: (ROIComputer.ProjectROI?, String?).self,
            returning: (rois: [ROIComputer.ProjectROI], skipped: [String]).self
        ) { group in
            var inFlight = 0
            var enqueued = 0
            var collected: [ROIComputer.ProjectROI] = []
            var skipped: [String] = []
            let maxInFlight = 8

            func enqueueNext() {
                while inFlight < maxInFlight, enqueued < projectPaths.count {
                    let path = projectPaths[enqueued]
                    let windows = windowsByProject[path] ?? []
                    enqueued += 1
                    inFlight += 1
                    group.addTask {
                        await Self.computeOne(
                            projectPath: path,
                            home: home,
                            windows: windows,
                            cutoff: cutoff
                        )
                    }
                }
            }

            enqueueNext()
            for await result in group {
                inFlight -= 1
                if let roi = result.0 { collected.append(roi) }
                if let s = result.1 { skipped.append(s) }
                enqueueNext()
            }
            return (collected, skipped)
        }

        rois = computed.rois
        skippedProjects = computed.skipped.sorted()
        lastComputedAt = Date()
    }

    /// Per-project pipeline: find git root → read commits → join to
    /// sessions → compute ROI. Returns `(roi, nil)` on success or
    /// `(nil, displayPath)` when we can't find a git repo to read
    /// from. Static so it crosses task boundaries without capturing
    /// `self` (which is `@MainActor` and would defeat the parallelism).
    private static func computeOne(
        projectPath: String,
        home: String,
        windows: [ROIComputer.SessionWindow],
        cutoff: Date
    ) async -> (ROIComputer.ProjectROI?, String?) {
        guard let root = await ProjectGitRootScanner.findGitRoot(
            from: projectPath,
            home: home
        ) else {
            return (nil, pacerShortPath(projectPath))
        }
        let rootURL = URL(fileURLWithPath: root)
        let commits = await GitLogReader.commits(
            in: rootURL,
            since: cutoff
        )
        // Skip rendering projects with neither commits nor sessions —
        // they'd show up as empty rows in the table.
        if commits.isEmpty && windows.isEmpty {
            return (nil, nil)
        }
        let roi = ROIComputer.computeProject(
            projectPath: projectPath,
            commits: commits,
            sessions: windows
        )
        // Skip projects with zero ROI signal — same reasoning as
        // above.
        if roi.commitCount == 0 && roi.attributedCostUSD == 0 {
            return (nil, nil)
        }
        return (roi, nil)
    }
}

private enum WindowOption: CaseIterable, Hashable {
    case sevenDays
    case thirtyDays
    case ninetyDays

    init(days: Int) {
        switch days {
        case ...7: self = .sevenDays
        case 8...30: self = .thirtyDays
        default: self = .ninetyDays
        }
    }

    var days: Int {
        switch self {
        case .sevenDays:  return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        }
    }

    var label: String {
        switch self {
        case .sevenDays:  return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        }
    }
}
