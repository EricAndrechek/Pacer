import SwiftUI
import UniformTypeIdentifiers
import PacerCore
import PacerUI

/// Redesigned collection editor. Built on the macOS Smart-Folder skeleton
/// everyone already knows (Identity → Rules → Members), with the two
/// things those editors lack and users asked for: **per-rule live match
/// previews** (Hazel) and a **folder picker that can stage data-less
/// folders**. Rules are folder-pickers by default with an explicit
/// glob-pattern option; project rows are disambiguated so "website" is
/// never ambiguous.
struct CollectionEditorSheet: View {
    let draft: CollectionEditorDraft
    let knownPaths: [String]
    let otherCollections: [(id: String, name: String)]
    let onSave: (CollectionEditorDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var colorHex: String?
    @State private var ruleDrafts: [RuleDraft] = []
    @State private var includePaths: [String] = []
    @State private var childIDs: Set<String> = []
    @State private var excludePaths: [String] = []
    @State private var projectFilter = ""

    @State private var showImporter = false
    @State private var importTarget: ImportTarget?

    /// Disambiguated labels across the projects this editor can show
    /// (known + already-staged members). Computed once from the draft.
    private let disambig: [String: String]
    private let knownSet: Set<String>

    init(
        draft: CollectionEditorDraft,
        knownPaths: [String],
        otherCollections: [(id: String, name: String)],
        onSave: @escaping (CollectionEditorDraft) -> Void
    ) {
        self.draft = draft
        self.knownPaths = knownPaths
        self.otherCollections = otherCollections
        self.onSave = onSave
        self.disambig = pacerDisambiguatedNames(Array(Set(knownPaths + draft.includePaths)))
        self.knownSet = Set(knownPaths)
    }

    enum ImportTarget: Equatable {
        case member
        case ruleFolder(UUID)
    }

    struct RuleDraft: Identifiable, Equatable {
        let id = UUID()
        var kind: Kind
        var value: String
        enum Kind { case folder, pattern }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Projects to list in the member checklist: every known project plus
    /// any already-staged (data-less) member, with staged ones surfaced.
    private var memberListPaths: [String] {
        let staged = includePaths.filter { !knownSet.contains($0) }
        let base = staged + knownPaths
        let needle = projectFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return base }
        return base.filter {
            $0.lowercased().contains(needle) || label(for: $0).lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            Form {
                identitySection
                rulesSection
                membersSection
                if !otherCollections.isEmpty { nestSection }
            }
            .formStyle(.grouped)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 620, height: 680)
        .onAppear(perform: load)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(pacerCollectionColor(seed: name.isEmpty ? "?" : name, hex: colorHex))
                .frame(width: 14, height: 14)
            Text(draft.editingID == nil ? "New collection" : "Edit collection")
                .font(.title3).fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Done") { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Identity

    private var identitySection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("e.g. Frontend, Client work"))
            CollectionColorField(seed: name, colorHex: $colorHex)
        } header: {
            Text("Identity")
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        Section {
            if ruleDrafts.isEmpty {
                Text("No rules. Add a folder to auto-include every project under it (now and in future), or a glob pattern for finer matches. A collection works fine with no rules — just hand-pick projects below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($ruleDrafts) { $rule in
                RuleRowView(
                    rule: $rule,
                    knownPaths: knownPaths,
                    label: label(for:),
                    onChooseFolder: {
                        importTarget = .ruleFolder(rule.id)
                        showImporter = true
                    },
                    onRemove: { ruleDrafts.removeAll { $0.id == rule.id } }
                )
            }
            HStack {
                Button {
                    let r = RuleDraft(kind: .folder, value: "")
                    ruleDrafts.append(r)
                    importTarget = .ruleFolder(r.id)
                    showImporter = true
                } label: { Label("Add folder", systemImage: "folder.badge.plus") }
                Button {
                    ruleDrafts.append(RuleDraft(kind: .pattern, value: ""))
                } label: { Label("Add pattern", systemImage: "asterisk") }
                    .help("Glob pattern, e.g. ~/Code/**/web-* . Use * within a folder and ** across folders.")
                Spacer()
            }
            .controlSize(.small)
        } header: {
            Text("Rules — auto-include matching projects")
        }
    }

    // MARK: Members

    private var membersSection: some View {
        Section {
            TextField("Filter projects", text: $projectFilter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            if memberListPaths.isEmpty {
                Text(projectFilter.isEmpty ? "No projects seen yet." : "No projects match.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(memberListPaths, id: \.self) { path in
                Button {
                    toggleMember(path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: includePaths.contains(path) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(includePaths.contains(path) ? Color.accentColor : Color.secondary)
                        DisambiguatedProjectRow(
                            path: path,
                            label: label(for: path),
                            staged: !knownSet.contains(path)
                        )
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                importTarget = .member
                showImporter = true
            } label: { Label("Add folder…", systemImage: "folder.badge.plus") }
                .controlSize(.small)
                .help("Tag a folder by hand — including one with no usage yet. It'll light up once Claude Code runs there.")
        } header: {
            HStack {
                Text("Projects — hand-picked")
                Spacer()
                Text("\(includePaths.count) selected").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Nest

    private var nestSection: some View {
        Section {
            ForEach(otherCollections, id: \.id) { other in
                Button {
                    if childIDs.contains(other.id) { childIDs.remove(other.id) }
                    else { childIDs.insert(other.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: childIDs.contains(other.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(childIDs.contains(other.id) ? Color.accentColor : Color.secondary)
                        Text(other.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Nest collections")
        } footer: {
            Text("A nested collection's projects roll up into this one too.")
        }
    }

    // MARK: Logic

    private func label(for path: String) -> String {
        disambig[path] ?? pacerShortPath(path)
    }

    private func toggleMember(_ path: String) {
        if let idx = includePaths.firstIndex(of: path) {
            includePaths.remove(at: idx)
        } else {
            includePaths.append(path)
            excludePaths.removeAll { $0 == path }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let url = (try? result.get())?.first else { return }
        let path = url.path
        switch importTarget {
        case .member:
            if !includePaths.contains(path) { includePaths.append(path) }
        case .ruleFolder(let id):
            if let i = ruleDrafts.firstIndex(where: { $0.id == id }) {
                ruleDrafts[i].value = path
            }
        case .none:
            break
        }
        importTarget = nil
    }

    private func load() {
        name = draft.name
        colorHex = draft.colorHex
        includePaths = draft.includePaths
        childIDs = draft.childCollectionIDs
        excludePaths = draft.excludePaths
        ruleDrafts = draft.rules.map {
            RuleDraft(kind: CollectionRuleMatcher.isGlob($0) ? .pattern : .folder, value: $0)
        }
    }

    private func commit() {
        var out = draft
        out.name = name
        out.colorHex = colorHex
        out.includePaths = includePaths
        out.childCollectionIDs = childIDs
        out.excludePaths = excludePaths
        out.rules = ruleDrafts.map(\.value)
        onSave(out)
    }
}

// MARK: - Rule row with live preview

private struct RuleRowView: View {
    @Binding var rule: CollectionEditorSheet.RuleDraft
    let knownPaths: [String]
    let label: (String) -> String
    let onChooseFolder: () -> Void
    let onRemove: () -> Void

    @State private var expanded = false

    private var matches: [String] {
        let v = rule.value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return [] }
        return knownPaths.filter { CollectionRuleMatcher.matches(path: $0, rule: v) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: rule.kind == .folder ? "folder" : "asterisk.circle")
                    .foregroundStyle(.secondary)
                if rule.kind == .folder {
                    Text(rule.value.isEmpty ? "Choose a folder…" : pacerShortPath(rule.value))
                        .foregroundStyle(rule.value.isEmpty ? .secondary : .primary)
                        .help(rule.value)
                    Button("Choose…", action: onChooseFolder).controlSize(.small)
                } else {
                    TextField("~/Code/**/web-*", text: $rule.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
                Spacer(minLength: 4)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            previewLine
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var previewLine: some View {
        let v = rule.value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty {
            Text(rule.kind == .folder ? "Pick a folder to see what it covers." : "Type a pattern to preview matches.")
                .font(.caption2).foregroundStyle(.tertiary)
        } else if matches.isEmpty {
            Label("no projects yet", systemImage: "circle")
                .font(.caption2).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(matches.count) project\(matches.count == 1 ? "" : "s")")
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(matches.prefix(40), id: \.self) { path in
                        Text(label(path))
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }
}

// MARK: - Reusable disambiguated project row

/// Leaf-or-disambiguated name on top, full path subline beneath
/// (middle-truncated), with an optional "staged · no data yet" tag for a
/// hand-added folder that has no usage. Used in the editor; reusable
/// wherever a project needs to be shown unambiguously.
struct DisambiguatedProjectRow: View {
    let path: String
    let label: String
    var staged: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(label).font(.callout).lineLimit(1).truncationMode(.middle)
                if staged {
                    Text("staged · no data yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            Text(path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Color field (swatch grid + custom picker)

private struct CollectionColorField: View {
    let seed: String
    @Binding var colorHex: String?

    private var selectedColor: Color {
        pacerCollectionColor(seed: seed.isEmpty ? "?" : seed, hex: colorHex)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Color").foregroundStyle(.secondary)
            Spacer()
            ForEach(Array(pacerColorPalette.enumerated()), id: \.offset) { _, color in
                let hex = pacerHexString(from: color)
                Button {
                    colorHex = hex
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(Color.primary.opacity(0.6), lineWidth: colorHex == hex ? 2 : 0)
                                .padding(-2)
                        )
                }
                .buttonStyle(.plain)
            }
            // Custom color escape hatch.
            ColorPicker("", selection: Binding(
                get: { selectedColor },
                set: { colorHex = pacerHexString(from: $0) }
            ))
            .labelsHidden()
            .frame(width: 32)
            .help("Custom color")
            if colorHex != nil {
                Button {
                    colorHex = nil
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reset to automatic color")
            }
        }
    }
}
