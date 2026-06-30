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
            if startNew && !didAutoStart {
                didAutoStart = true
                editor = CollectionEditorDraft()
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

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
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
        let ruleList = draft.rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : [draft.rule.trimmingCharacters(in: .whitespacesAndNewlines)]

        if let id = draft.editingID, let existing = collections.first(where: { $0.id == id }) {
            existing.name = trimmedName
            existing.includePaths = draft.includePaths.sorted()
            existing.childCollectionIDs = Array(draft.childCollectionIDs)
            existing.rules = ruleList
        } else {
            let collection = ProjectCollection(
                name: trimmedName,
                sortOrder: (collections.map(\.sortOrder).max() ?? 0) + 1,
                includePaths: draft.includePaths.sorted(),
                childCollectionIDs: Array(draft.childCollectionIDs),
                rules: ruleList
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
                .fill(pacerCollectionColor(seed: collection.colorSeed))
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
    var includePaths: Set<String> = []
    var childCollectionIDs: Set<String> = []
    var rule: String = ""

    init() {}

    init(from collection: ProjectCollection) {
        self.editingID = collection.id
        self.name = collection.name
        self.includePaths = Set(collection.includePaths)
        self.childCollectionIDs = Set(collection.childCollectionIDs)
        self.rule = collection.rules.first ?? ""
    }
}

// MARK: - Editor sheet

struct CollectionEditorSheet: View {
    let draft: CollectionEditorDraft
    let knownPaths: [String]
    /// (id, name) of every other collection — candidates for nesting.
    let otherCollections: [(id: String, name: String)]
    let onSave: (CollectionEditorDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var includePaths: Set<String> = []
    @State private var childCollectionIDs: Set<String> = []
    @State private var rule: String = ""
    @State private var projectFilter: String = ""

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredPaths: [String] {
        let needle = projectFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return knownPaths }
        return knownPaths.filter { $0.lowercased().contains(needle) }
    }

    private var ruleMatchCount: Int {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return knownPaths.filter { CollectionRuleMatcher.matches(path: $0, rule: trimmed) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(pacerCollectionColor(seed: name.isEmpty ? "?" : name))
                    .frame(width: 12, height: 12)
                Text(draft.editingID == nil ? "New collection" : "Edit collection")
                    .font(.headline)
            }

            TextField("Name (e.g. Frontend, Client work)", text: $name)
                .textFieldStyle(.roundedBorder)

            projectsSection

            if !otherCollections.isEmpty {
                subCollectionsSection
            }

            ruleSection

            HStack {
                if includePaths.isEmpty && childCollectionIDs.isEmpty && rule.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Empty for now — add projects, nest a collection, or set a rule.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            name = draft.name
            includePaths = draft.includePaths
            childCollectionIDs = draft.childCollectionIDs
            rule = draft.rule
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Projects").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(includePaths.count) selected").font(.caption2).foregroundStyle(.tertiary)
            }
            TextField("Filter projects", text: $projectFilter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredPaths.isEmpty {
                        Text("No projects match.").font(.caption).foregroundStyle(.tertiary).padding(6)
                    }
                    ForEach(filteredPaths, id: \.self) { path in
                        Button {
                            if includePaths.contains(path) { includePaths.remove(path) }
                            else { includePaths.insert(path) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: includePaths.contains(path) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(includePaths.contains(path) ? Color.accentColor : Color.secondary)
                                Text(pacerShortPath(path)).font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 160)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
        }
    }

    private var subCollectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nest collections (optional)").font(.caption).foregroundStyle(.secondary)
            ForEach(otherCollections, id: \.id) { other in
                Button {
                    if childCollectionIDs.contains(other.id) { childCollectionIDs.remove(other.id) }
                    else { childCollectionIDs.insert(other.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: childCollectionIDs.contains(other.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(childCollectionIDs.contains(other.id) ? Color.accentColor : Color.secondary)
                        Text(other.name).font(.callout)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var ruleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-include rule (optional)").font(.caption).foregroundStyle(.secondary)
            TextField("Folder prefix, e.g. ~/Code/work/acme", text: $rule)
                .textFieldStyle(.roundedBorder)
            if rule.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Leave blank for a purely hand-picked collection. A rule auto-includes every current and future project under that folder.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Matches \(ruleMatchCount) current project\(ruleMatchCount == 1 ? "" : "s") (plus any added later).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func commit() {
        var out = draft
        out.name = name
        out.includePaths = includePaths
        out.childCollectionIDs = childCollectionIDs
        out.rule = rule
        onSave(out)
    }
}
