import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Create / edit / delete project collections, presented as a sheet from
/// the Projects tab — the management counterpart to the Collections lane,
/// mirroring how `ProjectAliasManager` sits beside the project table.
///
/// Deliberately distinct from "Merge": a collection is a non-destructive,
/// overlapping, nestable *lens*, not an identity fold. Different verb
/// ("New collection" / "Add to collection"), different surface, different
/// visual language (an identity hue dot, not a merge arrow).
struct CollectionsManager: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\ProjectCollection.sortOrder, order: .reverse)])
    private var collections: [ProjectCollection]
    @Query private var aggregates: [ProjectDailyAggregate]

    /// When opened from a "New collection" button, jump straight into the
    /// editor instead of the list.
    var startNew: Bool = false
    /// When set, open straight into this collection's editor (from a
    /// scope-header / chip "Edit collection" action).
    var editCollectionID: String? = nil

    @State private var editor: CollectionEditorDraft?
    @State private var didAutoStart = false

    private var knownProjectPaths: [String] {
        var set: Set<String> = []
        for agg in aggregates where agg.projectPath != ProjectDailyAggregate.unknownProjectPath {
            set.insert(agg.projectPath)
        }
        return set.sorted()
    }

    private var rollups: [String: CollectionRollupResult] {
        Dictionary(
            CollectionUsageRollup.resolveAll(collections: collections, aggregates: aggregates)
                .map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                content.padding(20)
            }
        }
        .frame(width: 640, height: 600)
        .onAppear {
            guard !didAutoStart else { return }
            didAutoStart = true
            if startNew {
                editor = CollectionEditorDraft()
            } else if let id = editCollectionID,
                      let c = collections.first(where: { $0.id == id }) {
                editor = CollectionEditorDraft(from: c)
            }
        }
        .sheet(item: $editor) { draft in
            CollectionEditorSheet(
                draft: draft,
                knownPaths: knownProjectPaths,
                otherCollections: collections
                    .filter { $0.id != draft.editingID }
                    .map { ($0.id, $0.name) },
                onSave: save
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Collections")
                    .font(.title2).fontWeight(.semibold)
                Text("Group related projects — by hand, by folder rule, or by nesting one collection inside another.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var content: some View {
        // Resolve every collection's rollup ONCE per render. `resolveAll`
        // walks all aggregates, so subscripting `rollups` inside the
        // `ForEach` below re-ran that whole walk for every collection row.
        let rollups = rollups
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button {
                    editor = CollectionEditorDraft()
                } label: {
                    Label("New collection", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
            }

            if collections.isEmpty {
                emptyState
            } else {
                ForEach(collections) { collection in
                    CollectionManagerRow(
                        collection: collection,
                        memberCount: rollups[collection.id]?.memberCount ?? 0,
                        onEdit: { editor = CollectionEditorDraft(from: collection) },
                        onDelete: { delete(collection) }
                    )
                }
            }

            Text("A project can be in several collections at once. Collections don't change or hide your projects — they're an overlay you can rank, scope into, and budget separately.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    private var emptyState: some View {
        Text("No collections yet. Create one to roll up several projects — for example everything under a work folder, or a hand-picked set of related repos scattered across your machine.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }

    // MARK: Mutation

    private func save(_ draft: CollectionEditorDraft) {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let rules = draft.rules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let id = draft.editingID, let existing = collections.first(where: { $0.id == id }) {
            existing.name = trimmedName
            existing.colorHex = draft.colorHex
            existing.includePaths = draft.includePaths
            existing.childCollectionIDs = Array(draft.childCollectionIDs)
            existing.rules = rules
            existing.excludePaths = draft.excludePaths
        } else {
            let collection = ProjectCollection(
                name: trimmedName,
                colorHex: draft.colorHex,
                sortOrder: (collections.map(\.sortOrder).max() ?? 0) + 1,
                includePaths: draft.includePaths,
                childCollectionIDs: Array(draft.childCollectionIDs),
                rules: rules,
                excludePaths: draft.excludePaths
            )
            modelContext.insert(collection)
        }
        try? modelContext.save()
        editor = nil
    }

    private func delete(_ collection: ProjectCollection) {
        // Strip the deleted id from any parent so we don't leave dangling
        // child references behind (the resolver tolerates them, but a
        // clean graph is friendlier to audit).
        let deletedID = collection.id
        for other in collections where other.childCollectionIDs.contains(deletedID) {
            other.childCollectionIDs = other.childCollectionIDs.filter { $0 != deletedID }
        }
        modelContext.delete(collection)
        try? modelContext.save()
    }
}

// MARK: - Manager row

private struct CollectionManagerRow: View {
    let collection: ProjectCollection
    let memberCount: Int
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(pacerCollectionColor(seed: collection.colorSeed, hex: collection.colorHex))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(collection.name).font(.callout).fontWeight(.medium)
                    if !collection.rules.isEmpty {
                        Chip(text: "rule", systemImage: "line.3.horizontal.decrease.circle", tint: .secondary, size: .compact)
                    }
                    if !collection.childCollectionIDs.isEmpty {
                        Chip(text: "\(collection.childCollectionIDs.count) sub", systemImage: "square.stack.3d.up", tint: .secondary, size: .compact)
                    }
                }
                Text(membershipSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(memberCount) project\(memberCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Edit", action: onEdit)
                .controlSize(.small)
                .opacity(hovering ? 1 : 0)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete collection (your projects and usage are untouched)")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { hovering = $0 }
    }

    private var membershipSummary: String {
        var bits: [String] = []
        let manual = collection.includePaths.count
        if manual > 0 { bits.append("\(manual) hand-picked") }
        if let rule = collection.rules.first { bits.append("rule \(pacerShortPath(rule))") }
        if collection.childCollectionIDs.isEmpty == false { bits.append("nested") }
        return bits.isEmpty ? "empty" : bits.joined(separator: " · ")
    }
}

// MARK: - Editor draft

struct CollectionEditorDraft: Identifiable {
    let id = UUID()
    var editingID: String?
    var name: String = ""
    var colorHex: String? = nil
    /// Ordered so hand-added (incl. staged, data-less) projects stay put.
    var includePaths: [String] = []
    var childCollectionIDs: Set<String> = []
    var rules: [String] = []
    var excludePaths: [String] = []

    init() {}

    init(from collection: ProjectCollection) {
        self.editingID = collection.id
        self.name = collection.name
        self.colorHex = collection.colorHex
        self.includePaths = collection.includePaths
        self.childCollectionIDs = Set(collection.childCollectionIDs)
        self.rules = collection.rules
        self.excludePaths = collection.excludePaths
    }
}
