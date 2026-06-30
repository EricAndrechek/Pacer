import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Which lane the Projects tab is showing.
enum ProjectsSegment: String, CaseIterable, Identifiable {
    case projects, collections
    var id: String { rawValue }
    var label: String { self == .projects ? "Projects" : "Collections" }
}

/// How the Collections lane lays out — the in-product bake-off between
/// presentations. `lane` ranks collections among themselves (never
/// against projects); `tree` interleaves each collection with its member
/// projects under an expandable subtotal header. Scope-drill (clicking a
/// collection → `CollectionDetailView`) works from both.
enum CollectionsViewMode: String, CaseIterable, Identifiable {
    case lane, tree
    var id: String { rawValue }
    var label: String { self == .lane ? "Lane" : "Tree" }
    var systemImage: String { self == .lane ? "list.bullet" : "list.bullet.indent" }
}

/// The Collections side of the Projects tab. Kept entirely separate from
/// the perf-tuned `ProjectsContent` so the project leaderboard stays
/// leaf-only and untouched — collections live in their own lane.
struct CollectionsContent: View {
    @Query(sort: [SortDescriptor(\ProjectCollection.sortOrder, order: .reverse)])
    private var collections: [ProjectCollection]
    @Query private var aggregates: [ProjectDailyAggregate]

    let searchText: String
    let viewModeBinding: Binding<CollectionsViewMode>
    let onSelectCollection: (_ id: String) -> Void
    let onSelectProject: (_ path: String, _ displayName: String) -> Void
    /// Open the manager with the new-collection editor already showing.
    let onNew: () -> Void
    /// Open the manager to edit / delete existing collections.
    let onManage: () -> Void

    private let viewMode: CollectionsViewMode

    init(
        range: TimeRange,
        searchText: String,
        viewMode: CollectionsViewMode,
        viewModeBinding: Binding<CollectionsViewMode>,
        onSelectCollection: @escaping (_ id: String) -> Void,
        onSelectProject: @escaping (_ path: String, _ displayName: String) -> Void,
        onNew: @escaping () -> Void,
        onManage: @escaping () -> Void
    ) {
        self.searchText = searchText
        self.viewMode = viewMode
        self.viewModeBinding = viewModeBinding
        self.onSelectCollection = onSelectCollection
        self.onSelectProject = onSelectProject
        self.onNew = onNew
        self.onManage = onManage
        if let days = range.days,
           let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
            let cutoffString = TokenSample.formatDate(cutoffDate)
            _aggregates = Query(filter: #Predicate<ProjectDailyAggregate> { $0.date >= cutoffString })
        } else {
            _aggregates = Query()
        }
    }

    fileprivate struct LaneEntry: Identifiable {
        let collection: ProjectCollection
        let members: Set<String>
        let totals: ProjectUsageTotals
        var id: String { collection.id }
    }

    /// Resolve + roll up every collection, ranked by cost. Computed per
    /// render: the lane has no hover-driven chart re-fires (unlike the
    /// projects donut), and it's only on screen when the user picks the
    /// Collections segment, so the O(aggregates) fold is well within
    /// budget without a cache layer.
    private func entries(perPath: [String: ProjectUsageTotals]) -> [LaneEntry] {
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let knownPaths = Array(perPath.keys)
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return collections
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .map { c in
                let members = CollectionResolver.resolve(c.id, collections: byID, knownPaths: knownPaths)
                return LaneEntry(
                    collection: c,
                    members: members,
                    totals: CollectionUsageRollup.totals(for: members, perPath: perPath)
                )
            }
            .sorted { $0.totals.cost > $1.totals.cost }
    }

    var body: some View {
        let perPath = CollectionUsageRollup.perPathTotals(from: aggregates)
        let entries = entries(perPath: perPath)

        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            if collections.isEmpty {
                emptyCard
            } else {
                PacerCard("Collections", trailing: { laneControls }, content: {
                    if entries.isEmpty {
                        Text("No collections match \u{201C}\(searchText)\u{201D}.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        switch viewMode {
                        case .lane: laneList(entries)
                        case .tree: treeList(entries, perPath: perPath)
                        }
                    }
                }, footer: {
                    Text("Collections can overlap — a project in two collections counts in both, so the totals here don't add up to your overall usage. Each collection is its own lens.")
                })
            }
        }
    }

    /// Controls in the card's title row (rendered by PacerCard's trailing
    /// slot): the lane/tree toggle, a prominent New, and Manage.
    private var laneControls: some View {
        HStack(spacing: 8) {
            Picker("View", selection: viewModeBinding) {
                ForEach(CollectionsViewMode.allCases) { mode in
                    Image(systemName: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 96)
            .controlSize(.small)
            .labelsHidden()
            .help("Switch between the ranked lane and the collapsible tree.")
            Button(action: onNew) {
                Label("New collection", systemImage: "plus.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
            .help("Create another collection.")
            Button("Manage…", action: onManage)
                .controlSize(.small)
                .help("Edit or delete existing collections.")
        }
    }

    private var emptyCard: some View {
        PacerCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("No collections yet.").font(.body).foregroundStyle(.secondary)
                Text("Group related projects into a collection — by hand (a scattered set of repos), by folder rule (everything under a work directory), or by nesting one collection inside another. Collections never change your projects; they're an overlay you can rank, scope into, and budget.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    onNew()
                } label: {
                    Label("New collection", systemImage: "plus.circle.fill").labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    // MARK: Lane mode

    private func laneList(_ entries: [LaneEntry]) -> some View {
        let maxCost = entries.map(\.totals.cost).max() ?? 0
        return VStack(spacing: 0) {
            ForEach(entries) { entry in
                HoverRow(action: { onSelectCollection(entry.id) }) {
                    laneRow(entry, maxCost: maxCost)
                }
            }
        }
    }

    private func laneRow(_ entry: LaneEntry, maxCost: Double) -> some View {
        let hue = pacerCollectionColor(seed: entry.collection.colorSeed, hex: entry.collection.colorHex)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(hue).frame(width: 9, height: 9)
                Text(entry.collection.name).font(.callout).fontWeight(.medium)
                if !entry.collection.rules.isEmpty {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help("Has an auto-include rule")
                }
                if !entry.collection.childCollectionIDs.isEmpty {
                    Image(systemName: "square.stack.3d.up")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help("Nests other collections")
                }
                Text("\(entry.members.count) project\(entry.members.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(pacerCost(entry.totals.cost))
                    .font(.callout).monospacedDigit()
                    .help(pacerCostExact(entry.totals.cost))
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(hue.opacity(0.5))
                    .frame(width: maxCost > 0 ? geo.size.width * (entry.totals.cost / maxCost) : 0, height: 4)
            }
            .frame(height: 4)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    // MARK: Tree mode

    private func treeList(_ entries: [LaneEntry], perPath: [String: ProjectUsageTotals]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries) { entry in
                CollectionTreeRow(
                    entry: entry,
                    perPath: perPath,
                    onSelectCollection: onSelectCollection,
                    onSelectProject: onSelectProject
                )
            }
        }
    }
}

/// One expandable collection in tree mode: a subtotal header (the
/// roll-up sits over its children, never as a peer in the same sorted
/// axis) with member projects indented beneath.
private struct CollectionTreeRow: View {
    let entry: CollectionsContent.LaneEntry
    let perPath: [String: ProjectUsageTotals]
    let onSelectCollection: (_ id: String) -> Void
    let onSelectProject: (_ path: String, _ displayName: String) -> Void
    @State private var expanded = false

    private var rankedMembers: [(path: String, cost: Double)] {
        entry.members
            .map { ($0, perPath[$0]?.cost ?? 0) }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        let hue = pacerCollectionColor(seed: entry.collection.colorSeed, hex: entry.collection.colorHex)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                }
                .buttonStyle(.plain)
                Circle().fill(hue).frame(width: 9, height: 9)
                Button { onSelectCollection(entry.id) } label: {
                    Text(entry.collection.name).font(.callout).fontWeight(.medium)
                }
                .buttonStyle(.plain)
                Text("\(entry.members.count)").font(.caption2).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(pacerCost(entry.totals.cost)).font(.callout).fontWeight(.medium).monospacedDigit()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)

            if expanded {
                if rankedMembers.isEmpty {
                    Text("No member projects with activity in range.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.leading, 38).padding(.bottom, 4)
                } else {
                    ForEach(rankedMembers, id: \.path) { member in
                        Button { onSelectProject(member.path, pacerShortPath(member.path)) } label: {
                            HStack(spacing: 8) {
                                Text(pacerShortPath(member.path)).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(pacerCost(member.cost)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 2)
                            .padding(.leading, 38).padding(.trailing, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(expanded ? Color.primary.opacity(0.03) : Color.clear)
        )
    }
}
