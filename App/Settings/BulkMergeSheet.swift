import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Payload for `BulkMergeSheet` when presented via `.sheet(item:)`.
/// Lives at file scope so both `ProjectsView` and `ProjectAliasesCard`
/// can drive the same sheet without redefining the wrapper.
///
/// `canonical` may be empty (sheet shows a blank picker; the user
/// fills in the target). `sources` may be empty (the user checks the
/// rows in-sheet). Non-empty values pre-seed the sheet — useful when
/// launched from a row's "Merge others into this…" context-menu
/// item, which already knows the canonical.
struct BulkMergeDraft: Identifiable, Equatable {
    let id = UUID()
    let canonical: String
    let sources: Set<String>
}

/// One-shot "merge N projects into 1 canonical" dialog. Replaces the
/// editor-sheet-per-alias loop that made multi-project cleanup feel
/// tedious — a renamed repo (`ccmac` → `Pacer`) usually leaves a
/// handful of derivative project paths behind (`ccmac`,
/// `ccmac/PacerCore`, `ccmac/.worktrees/...`) and the user wants to
/// fold all of them into the current path in one move.
///
/// Layout:
///   • Top row: canonical picker (`TextField` + "Pick from known
///     projects" menu — same affordance as `AliasEditorSheet`).
///   • Middle: scrollable, filterable list of every known project
///     with a checkbox in front. The canonical row is hidden so the
///     user can't accidentally alias something to itself.
///   • Bottom: "Merge N projects" primary button + error region for
///     anything `ProjectPathAliasManager` rejected (cycle, empty).
///
/// Why a sheet instead of inline editing: the user typically has
/// 5–10+ sources to pick. Doing this inline in the Projects table or
/// Settings card would require multi-selection on a `LazyVStack`
/// (non-trivial) and would distract from the table's read-only
/// browse purpose. A focused sheet matches the user's task.
struct BulkMergeSheet: View {
    /// Every project path Pacer has seen (post-canonicalization), used
    /// to populate both the canonical picker and the source list.
    let knownPaths: [String]
    /// Pre-fill the canonical picker. Useful when launched from a
    /// row's "Merge others into this…" context-menu action — the
    /// user already picked the target by right-clicking on its row.
    let initialCanonical: String?
    /// Pre-check these source rows. Used the same way as
    /// `initialCanonical` for the multi-row context-menu entry point.
    let initialSources: Set<String>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Aggregates fuel the `lastActive` / `sessionCount` per-path
    /// stats. Unscoped: we want a project's full history, not just
    /// the active range from `ProjectsView`, so the "last seen 6
    /// weeks ago" badge on a phantom path reads honestly.
    @Query private var aggregates: [ProjectDailyAggregate]
    /// Existing aliases — surfaced inline so the user sees which
    /// sources already chain somewhere ("→ /Users/foo/Pacer") rather
    /// than discovering it via a cycle error after they hit Merge.
    @Query(sort: [SortDescriptor(\ProjectPathAlias.createdAt, order: .reverse)])
    private var aliases: [ProjectPathAlias]

    @State private var canonicalPath: String = ""
    @State private var selectedSources: Set<String> = []
    @State private var filterText: String = ""
    /// Per-source errors raised by `ProjectPathAliasManager`. Cleared
    /// at the top of every save attempt so partial-failure runs don't
    /// leak stale messages.
    @State private var errors: [String: String] = [:]
    /// Cached per-path snapshot (`lastActive`, `sessionCount`,
    /// `existsOnDisk`). The "exists on disk" check hits the
    /// filesystem; doing it once on appear (instead of per body
    /// render) keeps the sheet snappy. Aggregates feed the recency
    /// stats — same idea: bucket once, not per row.
    @State private var pathInfo: [String: PathInfo] = [:]

    /// What we know about a path. Drives sort order, the "on disk"
    /// badge, and the relative-time label. Phantom paths (the old
    /// `ccmac` directory that no longer exists) jump to the top of
    /// the source list — they're the most likely things to merge
    /// AWAY from.
    struct PathInfo: Equatable {
        let lastActive: Date
        let sessionCount: Int
        let existsOnDisk: Bool
    }

    /// Selectable rows (everything in `knownPaths` minus the canonical
    /// and the synthetic "(unknown)" sentinel — aliasing the bucket
    /// for path-less samples to a real project would be a footgun).
    /// Sorted so the user's eyes land on the right rows first:
    ///   1. Missing-on-disk paths (most likely renames to merge AWAY).
    ///   2. On-disk paths.
    /// Within each group, most-recent activity first so old phantoms
    /// and stale worktrees still rank by relevance.
    private var sourceCandidates: [String] {
        let raw = knownPaths
            .filter { $0 != canonicalPath }
            .filter { $0 != ProjectDailyAggregate.unknownProjectPath }
        return raw.sorted { a, b in
            let ia = pathInfo[a]
            let ib = pathInfo[b]
            let aMissing = !(ia?.existsOnDisk ?? true)
            let bMissing = !(ib?.existsOnDisk ?? true)
            if aMissing != bMissing { return aMissing && !bMissing }
            // Same on-disk status: sort by recency (newest first).
            let aDate = ia?.lastActive ?? .distantPast
            let bDate = ib?.lastActive ?? .distantPast
            if aDate != bDate { return aDate > bDate }
            return a < b // stable tiebreaker
        }
    }

    /// Filter applied AFTER `sourceCandidates` so the canonical/unknown
    /// rows are never reachable through the search field either.
    private var filteredSources: [String] {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sourceCandidates }
        return sourceCandidates.filter { path in
            path.lowercased().contains(needle) ||
            pacerShortPath(path).lowercased().contains(needle)
        }
    }

    /// Same sort as `sourceCandidates` but for the canonical picker
    /// menu — there we want on-disk FIRST (since you're picking the
    /// destination, you almost always want a real directory). Within
    /// each group, most-recent first so the obvious answer ("Pacer,
    /// active today") shows up at the top.
    private var canonicalCandidates: [String] {
        let raw = knownPaths.filter { $0 != ProjectDailyAggregate.unknownProjectPath }
        return raw.sorted { a, b in
            let ia = pathInfo[a]
            let ib = pathInfo[b]
            let aOnDisk = ia?.existsOnDisk ?? true
            let bOnDisk = ib?.existsOnDisk ?? true
            if aOnDisk != bOnDisk { return aOnDisk && !bOnDisk }
            let aDate = ia?.lastActive ?? .distantPast
            let bDate = ib?.lastActive ?? .distantPast
            if aDate != bDate { return aDate > bDate }
            return a < b
        }
    }

    private var existingAliasMap: [String: String] {
        Dictionary(uniqueKeysWithValues: aliases.map { ($0.sourcePath, $0.canonicalPath) })
    }

    private var canonicalIsValid: Bool {
        let c = canonicalPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !c.isEmpty
    }
    private var canMerge: Bool {
        canonicalIsValid && !selectedSources.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            canonicalPicker
            sourceList
            if !errors.isEmpty { errorSummary }
            footer
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 620)
        .onAppear {
            // `initial*` fields are forwarded from the caller's
            // context (which row was right-clicked, which canonical
            // was preselected). We populate @State once on appear so
            // the user's edits aren't clobbered by view re-creation.
            if canonicalPath.isEmpty, let initial = initialCanonical {
                canonicalPath = initial
            }
            if selectedSources.isEmpty {
                selectedSources = initialSources
            }
            refreshPathInfo()
            autoPickCanonicalIfNeeded()
        }
        // SwiftData @Query collections are arrays; comparing `.count`
        // is a cheap stable-ish trigger that fires when the scan
        // committed new data while the sheet is open. Recomputing
        // pathInfo on `knownPaths` change too — the caller might
        // hand us a different snapshot if the user filtered or
        // switched range underneath us.
        .onChange(of: aggregates.count) { _, _ in refreshPathInfo() }
        .onChange(of: knownPaths) { _, _ in refreshPathInfo() }
    }

    // MARK: - Stats

    /// Bucket `aggregates` by path once, then layer in a filesystem
    /// `fileExists` check per path. The fs check is sync and fast
    /// (~hundreds of µs each) — fine for the typical 5–50 known
    /// paths. We deliberately don't watch for fs changes mid-sheet:
    /// projects don't appear/disappear at that cadence and a stale
    /// badge is far less surprising than a flicker.
    private func refreshPathInfo() {
        struct Acc {
            var lastActive: Date = .distantPast
            var sessions: Int = 0
        }
        var byPath: [String: Acc] = [:]
        for r in aggregates {
            var a = byPath[r.projectPath] ?? Acc()
            if r.lastActive > a.lastActive { a.lastActive = r.lastActive }
            a.sessions += r.sessionCount
            byPath[r.projectPath] = a
        }
        let fm = FileManager.default
        var out: [String: PathInfo] = [:]
        out.reserveCapacity(knownPaths.count)
        for path in knownPaths {
            let acc = byPath[path] ?? Acc()
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            out[path] = PathInfo(
                lastActive: acc.lastActive,
                sessionCount: acc.sessions,
                existsOnDisk: exists
            )
        }
        pathInfo = out
    }

    /// Smart default for the canonical when the caller didn't
    /// preseed one. Picks the most-recently-active on-disk path —
    /// the canonical you'd almost always want for the rename case.
    /// Only runs once (when the field is empty); the user's typed
    /// value is never overwritten.
    private func autoPickCanonicalIfNeeded() {
        guard canonicalPath.isEmpty else { return }
        let onDisk = knownPaths
            .filter { $0 != ProjectDailyAggregate.unknownProjectPath }
            .filter { pathInfo[$0]?.existsOnDisk == true }
        let best = onDisk.max { lhs, rhs in
            (pathInfo[lhs]?.lastActive ?? .distantPast) <
            (pathInfo[rhs]?.lastActive ?? .distantPast)
        }
        if let best { canonicalPath = best }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Merge projects")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Pick the canonical project (the path you currently use), then check every old/historical path that should fold into it. Pacer re-attributes existing samples on the next scan cycle.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Canonical picker

    private var canonicalPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Keep as canonical")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("(samples will move here)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                TextField("/Users/you/Code/current-name", text: $canonicalPath)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    let onDisk = canonicalCandidates.filter { pathInfo[$0]?.existsOnDisk == true }
                    let missing = canonicalCandidates.filter { pathInfo[$0]?.existsOnDisk == false }
                    if !onDisk.isEmpty {
                        Section("On disk") {
                            ForEach(onDisk, id: \.self) { path in
                                canonicalMenuItem(path)
                            }
                        }
                    }
                    if !missing.isEmpty {
                        Section("No longer on disk") {
                            ForEach(missing, id: \.self) { path in
                                canonicalMenuItem(path)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Pick from known projects (most-recently-active on-disk path appears first)")
            }
            // Inline read-out of the currently-selected canonical's
            // state, so the user can confirm at a glance that they
            // picked the live directory and not a phantom.
            if let info = pathInfo[canonicalPath] {
                canonicalStatusLine(for: canonicalPath, info: info)
            }
        }
    }

    /// One menu item used by both sections of the canonical picker.
    /// Folds "on disk · 2m ago" into the title because `Menu` items
    /// don't render styled custom labels reliably in the current
    /// SwiftUI version.
    @ViewBuilder
    private func canonicalMenuItem(_ path: String) -> some View {
        Button(canonicalMenuLabel(for: path)) {
            canonicalPath = path
        }
    }

    /// Plain (non-@ViewBuilder) helper: builds the menu-item title
    /// string. Lives outside the @ViewBuilder so the `if`-binding
    /// for `info.lastActive` is interpreted as control flow rather
    /// than a SwiftUI view expression (which fails with "type '()'
    /// cannot conform to 'View'").
    private func canonicalMenuLabel(for path: String) -> String {
        let info = pathInfo[path]
        let badge = info?.existsOnDisk == true ? "on disk" : "missing"
        let recency: String
        if let info, info.lastActive != .distantPast {
            recency = pacerRelative(info.lastActive)
        } else {
            recency = "no activity"
        }
        return "\(pacerShortPath(path)) — \(badge) · \(recency)"
    }

    @ViewBuilder
    private func canonicalStatusLine(for path: String, info: PathInfo) -> some View {
        HStack(spacing: 6) {
            OnDiskBadge(existsOnDisk: info.existsOnDisk)
            if info.lastActive != .distantPast {
                Text("last active \(pacerRelative(info.lastActive))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !info.existsOnDisk {
                Text("Canonical path doesn't currently exist on disk — usually you want the new folder name.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Source list

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Fold into canonical")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("(missing-on-disk paths first; these are usually the old/renamed ones)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !selectedSources.isEmpty {
                    Button("Clear") { selectedSources.removeAll() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                if !filteredSources.isEmpty {
                    Button(allFilteredSelected ? "Deselect filtered" : "Select filtered") {
                        toggleFilteredSelection()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            // Quick "fold every missing path into the canonical" shortcut.
            // The 80% workflow for the rename case: there's exactly one
            // on-disk path (the new name) and several missing ones (the
            // old folders Claude Code captured before the rename). One
            // click checks all of them.
            if missingSourceCount > 0 {
                Button {
                    selectMissingSources()
                } label: {
                    Label("Select all \(missingSourceCount) missing path\(missingSourceCount == 1 ? "" : "s")",
                          systemImage: "folder.badge.questionmark")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            TextField("Filter by path or name", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredSources.isEmpty {
                        Text(sourceCandidates.isEmpty
                             ? "No other projects to merge."
                             : "No projects match \u{201C}\(filterText)\u{201D}.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(filteredSources, id: \.self) { path in
                            sourceRow(path)
                            if path != filteredSources.last {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var allFilteredSelected: Bool {
        !filteredSources.isEmpty && filteredSources.allSatisfy { selectedSources.contains($0) }
    }

    private func toggleFilteredSelection() {
        if allFilteredSelected {
            for p in filteredSources { selectedSources.remove(p) }
        } else {
            for p in filteredSources { selectedSources.insert(p) }
        }
    }

    /// Count of source candidates whose directory no longer exists.
    /// Drives the "Select all N missing paths" shortcut — the
    /// shortcut is hidden when 0 to avoid an action that does nothing.
    private var missingSourceCount: Int {
        sourceCandidates.filter { pathInfo[$0]?.existsOnDisk == false }.count
    }

    private func selectMissingSources() {
        for path in sourceCandidates where pathInfo[path]?.existsOnDisk == false {
            selectedSources.insert(path)
        }
    }

    @ViewBuilder
    private func sourceRow(_ path: String) -> some View {
        let isSelected = selectedSources.contains(path)
        let existingTarget = existingAliasMap[path]
        let info = pathInfo[path]
        Button {
            toggle(path)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .imageScale(.medium)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pacerShortPath(path))
                            .font(.callout)
                            .foregroundStyle(.primary)
                        if let info {
                            OnDiskBadge(existsOnDisk: info.existsOnDisk)
                        }
                        if let info, info.lastActive != .distantPast {
                            Text(pacerRelative(info.lastActive))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let existingTarget {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(pacerShortPath(existingTarget))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .help("Already aliased — saving will rewrite this row.")
                        }
                    }
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let err = errors[path] {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ path: String) {
        if selectedSources.contains(path) {
            selectedSources.remove(path)
        } else {
            selectedSources.insert(path)
        }
    }

    // MARK: - Errors

    private var errorSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text("\(errors.count) row\(errors.count == 1 ? "" : "s") couldn't be merged. See messages above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(mergeButtonTitle) { performMerge() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canMerge)
                .buttonStyle(.borderedProminent)
        }
    }

    private var mergeButtonTitle: String {
        guard !selectedSources.isEmpty else { return "Merge" }
        return "Merge \(selectedSources.count) project\(selectedSources.count == 1 ? "" : "s")"
    }

    // MARK: - Mutation

    private func performMerge() {
        let canonical = canonicalPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        let manager = ProjectPathAliasManager(context: modelContext)
        // One batched call instead of N upsert+save round-trips.
        // SwiftData's `context.save()` is the dominant cost (disk
        // flush + @Query notification storm); paying it once for the
        // whole batch keeps the main thread responsive even with 20+
        // sources selected.
        let entries = selectedSources.map { (source: $0, canonical: canonical) }
        var newErrors: [String: String] = [:]
        var successCount = 0
        do {
            let results = try manager.upsertMany(entries)
            for r in results {
                if let err = r.error {
                    newErrors[r.source] = err.userMessage
                } else {
                    successCount += 1
                }
            }
        } catch {
            // `upsertMany` only throws when the final save fails (a
            // store-level error: disk full, schema mismatch). Treat
            // it as "everything failed" — none of the rows are
            // committed by SwiftData when save throws.
            for source in selectedSources {
                newErrors[source] = error.localizedDescription
            }
            successCount = 0
        }
        errors = newErrors
        // Drop the successfully-merged rows from the selection so a
        // second click of Merge after fixing the broken ones doesn't
        // re-upsert the already-clean ones.
        if successCount > 0 {
            selectedSources = selectedSources.filter { newErrors[$0] != nil }
            // Kick a scan cycle immediately so the user sees the
            // re-attribution land instead of waiting on the watcher
            // backstop. AppBackgroundService observes this and calls
            // ScanCoordinator.runOnce; overlapping requests collapse
            // safely.
            NotificationCenter.default.post(name: .pacerRequestImmediateScan, object: nil)
        }
        // Close only when every selected source landed. Leaving the
        // sheet open on partial failure lets the user fix the error
        // (e.g. change canonical to break a cycle) and retry without
        // losing their selection.
        if newErrors.isEmpty {
            dismiss()
        }
    }
}

// MARK: - User-facing error messages

private extension ProjectPathAliasManager.AliasError {
    var userMessage: String {
        switch self {
        case .selfAlias:        return "Same as canonical."
        case .emptyPath:        return "Path is empty."
        case .wouldCreateCycle: return "Would create a loop."
        }
    }
}

// MARK: - On-disk badge

/// Pill that announces whether a project path currently exists as a
/// directory. The single highest-signal distinguisher between "old
/// path you've renamed away from" and "current path you're working
/// in" — especially in the rename case the user described, where two
/// project paths have totally different basenames (`ccmac` vs
/// `Pacer`) and similar overall trees.
///
/// Color choices:
///   • On disk → subtle secondary tone; this is the expected, calm
///     state. We don't want to distract from the actual content.
///   • Missing → orange; an attention-grabber, because the row is
///     almost certainly something the user wants to merge AWAY.
private struct OnDiskBadge: View {
    let existsOnDisk: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: existsOnDisk ? "folder.fill" : "folder.badge.questionmark")
                .font(.system(size: 9))
            Text(existsOnDisk ? "on disk" : "missing")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(existsOnDisk ? Color.secondary : Color.orange)
        .background(
            Capsule().fill(
                existsOnDisk ? Color.secondary.opacity(0.12) : Color.orange.opacity(0.16)
            )
        )
        .accessibilityLabel(existsOnDisk ? "On disk" : "No longer on disk")
    }
}
