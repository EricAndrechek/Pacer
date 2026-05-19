import SwiftUI
import PacerCore
import PacerUI

/// Small pill announcing a project's filesystem + git status.
/// Renders next to the project name in the Projects list and under
/// the project-detail subtitle. Three states cover what's actionable
/// for the user without adding visual noise:
///
/// - `.git` — directory exists on disk AND has a `.git` ancestor.
///   The default state for a healthy git-tracked project; rendered
///   subtle/secondary so it doesn't shout.
/// - `.noGit` — directory exists but no `.git` is reachable by
///   walking up. Slightly louder (orange-ish) because it's the
///   unusual case the user probably wants to spot — random folders
///   where Claude Code ran, not part of a real repo.
/// - `.missing` — directory no longer exists. Loud (orange) because
///   it usually means the folder was renamed/deleted and the user
///   may want to merge the historical samples into the current
///   path.
///
/// `.unknown` is shown when the probe hasn't run yet for a path
/// (first launch right after install, before the scan cycle wrote
/// a probe row). Renders as no badge at all — better than
/// surfacing a misleading state.
struct ProjectStatusBadge: View {
    enum State: Equatable {
        case git
        case noGit
        case missing
        case unknown
    }

    let state: State

    var body: some View {
        switch state {
        case .git:     pill(icon: "arrow.triangle.branch", text: "git", color: .secondary)
        case .noGit:   pill(icon: "folder", text: "no git", color: .orange)
        case .missing: pill(icon: "folder.badge.questionmark", text: "missing", color: .orange)
        case .unknown: EmptyView()
        }
    }

    @ViewBuilder
    private func pill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
        .accessibilityLabel(Text(text))
    }
}

/// Derive the badge state for a project path from a probe lookup
/// + filesystem check. Both inputs are typically cached at the
/// call site so this is cheap.
///
/// `probesByPath` is `[projectPath: ProjectPathProbe]` from the
/// caller's @Query / cached snapshot. The fs check is a single
/// `fileExists`/`isDirectory` syscall.
@MainActor
func projectStatusBadgeState(
    for path: String,
    probesByPath: [String: ProjectPathProbe],
    existsOnDisk: Bool
) -> ProjectStatusBadge.State {
    if !existsOnDisk { return .missing }
    // Probe rows record gitRoot when the walk-up found a `.git`.
    // Two ways a path qualifies as "git":
    //   1. It IS its own gitRoot (probe.gitRoot == path).
    //   2. It's been aliased to a git root and the canonical
    //      shows that path → in that case the probe lookup is on
    //      the canonical, which itself has gitRoot == path.
    // The post-canonicalization paths we show in the Projects list
    // are typically case 1 — they ARE git roots after auto-merge.
    guard let probe = probesByPath[path] else { return .unknown }
    return probe.gitRoot != nil ? .git : .noGit
}
