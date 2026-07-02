# Project Collections — design

Status: **shipped (v0.3.16, PR #110).** Non-destructive, overlapping,
nestable collections, integrated *inside* the Projects tab — not a
separate tab. The first cut (a separate Projects | Collections tab with a
lane/tree/detail modal) was scrapped after real-world use: it felt
bolted-on and the editor was confusing. This doc records the design that
shipped; if implementation diverges, update the doc.

**What shipped:**
- Collections live in the Projects tab: a **filter bar** (chip per
  collection, click to scope the donut + table), **membership dots** on
  each project row (names on hover), **"Add to collection…"** on
  right-click, and a **"Made up of"** composition breakdown when a scoped
  collection nests others.
- A rebuilt **editor** (Smart-Folder skeleton): folder-picker rules with
  live match previews + real globs (`*`/`**`), multi-rule, stage
  data-less folders, disambiguated project rows, color palette + custom
  picker.
- Core: `ProjectCollection` (references not leaves; cycle-safe resolver;
  rollup as a second fold), `ProjectMeta` (per-project color store),
  reverse membership index, `pacerDisambiguatedNames`. All additive.

**Colors shipped:** stable, pretty identity colors for projects and models
now drive every donut/legend/dot — see [identity-colors.md](identity-colors.md).
The per-project color *picker* was **declined** (Eric chose auto colors that
never need managing over a color well); collections keep their manual
`colorHex` picker. The color system is a pure function of a recorded seed
(survives rename/remote), so no per-view management is needed.

**Deferred follow-ups:** scoping History (Dashboard pace/rate-limit stay
account-wide — they can't scope).

## What v1 got right (keep)

- The **data spine** is sound and stays: `ProjectCollection` (references,
  not flattened leaves), `CollectionResolver` (cycle-safe transitive
  resolve → `Set<leafPath>`), `CollectionUsageRollup` (second fold over
  `ProjectDailyAggregate`, no new aggregate table). See PR #110.
- **Scope-drill** detail (total as a header spotlight, members ranked
  within) and the **overlap-honesty** stance (collection totals don't sum).
- **Manual membership is first-class** (no rule required).

## What v1 got wrong (the feedback)

1. Rules are opaque — you can't see what a rule covers, can't tell whether
   globs work (they don't — it's prefix-only), and can't set multiple.
2. The project picker shows ambiguous leaf names ("website" — in *what*?)
   with no path context.
3. You can't pre-tag a folder that has no sessions yet but soon will.
4. No custom colors (collections or projects).
5. Collections feel bolted-on — not integrated the way projects are — so
   they won't get used.

The rest of this doc addresses each, grounded in established macOS patterns
and the existing codebase.

---

## 1. The editor redesign

A single `Form { Section … }` sheet (`.formStyle(.grouped)`), ~600pt wide.
Replaces the dense ad-hoc sheet. Anchored on the **Smart-Folder skeleton**
(Finder / Photos Smart Albums / Lightroom Smart Collections all share it)
plus two things those don't do that we must: **Hazel-style live per-rule
previews** and a **directory picker for staging**.

```
┌─ Edit collection ─────────────────────────────────────────────┐
│  ●  Name  [ Frontend Apps                                    ]  │  Identity
│     Color ◯ ◯ ◯ ◉ ◯ ◯ ◯ ◯  [⋯ Custom]                          │
│                                                                │
│  RULES — auto-include projects under a folder                  │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ 📁  ~/Code/work/acme              [Choose…]            ⊖  │ │  one rule row…
│  │     ✓ 4 projects   ▸ api · firmware · web · cloud-infra   │ │  live preview (names!)
│  ├──────────────────────────────────────────────────────────┤ │
│  │ 📁  ~/Code/frontend               [Choose…]            ⊖  │ │  …multiple rows
│  │     ○ no projects yet                                     │ │  0-match is fine, not an error
│  └──────────────────────────────────────────────────────────┘ │
│                          [ + Add folder ]   [ + Pattern (adv) ]│
│                                                                │
│  MEMBERS — hand-picked, regardless of rules                    │
│  ● acme-dashboard      ~/Code/work/acme            [data]   ⊖  │  disambiguated rows
│  ○ new-marketing-site  ~/Code/work/marketing  [staged · no    │  staged empty folder
│                                                 data yet]   ⊖  │
│                                          [ + Add folder… ]      │
│                                                                │
│  [Delete]                                   [Cancel]  [Done]   │
└────────────────────────────────────────────────────────────────┘
```

### Rules
- **Each rule is a row**: a path + `[Choose…]` (NSOpenPanel / `.fileImporter`
  directory picker — never freehand typing for folders) + a remove control.
  "+ Add folder" appends rows → **multiple rules** (the model already stores
  `[String]`). Semantics: "everything under this folder, recursively"
  (Timing's `Path begins with`). Union across rows (`Any`) — we don't expose
  All/None, which is meaningless for folder prefixes.
- **Live preview per row (the key fix):** as you pick/edit, the row shows a
  status line with the **actual matched project names**, not just a count
  (Hazel's defining move — a count can't tell you whether the *right* things
  matched). Expandable disclosure for the full list. Debounced ~250ms, matched
  off-main against the in-memory project index. `0` matches → neutral
  `○ no projects yet` (legitimate for staging), red only for *invalid* input.
- **Globs are gated, not faked.** The current field implies glob support but
  is prefix-only — that lie is the #1 confusion. v1-redesign ships the
  **Folder picker only**; a "Pattern (advanced)" rule type that actually
  implements `*`/`**` (VS Code/minimatch semantics) lands behind a flag once
  built. Never accept `*` that's silently treated as a literal.

### Members (manual) + staging empty folders
- "+ Add folder…" (`.fileImporter`, `allowedContentTypes: [.folder]`) adds
  **any** directory — including one with no usage yet. Persist a
  **security-scoped bookmark** at pick time so a data-less staged folder
  survives relaunch.
- Staged/empty members render distinctly: hollow `○` + muted `staged · no
  data yet`, vs filled `●` for folders with data. They light up automatically
  when Claude Code first runs there.

### Disambiguated project rows (reused everywhere)
- One reusable row: **leaf name + full path subline** (`.truncationMode(.middle)`,
  `.secondary`). Add a **parent-folder prefix** (`clientA / website`) *only
  when the leaf collides* with another visible project; group the add-picker
  by parent directory.
- Powered by a new collision-aware helper in `PacerUI/Formatters.swift`:
  `pacerDisambiguatedNames(_ paths:) -> [String: String]` (leaf, extended with
  parent components until unique). Computed app-wide once per scan tick,
  cached next to `cachedAllRows`, threaded into `ProjectRow.displayName`
  (`ProjectsView.computeAllRowsSync`, ~`:458`) so the table, donut, and
  detail title inherit it for free; also used by the editor picker and
  collection member rows.

### Color
- **Curated swatch grid + "Custom…" escape hatch** (Apple Calendar / Finder
  tags / Things pattern): `LazyVGrid` of `Circle` swatches (selected = ring,
  not fill) → covers ~90%; trailing `[⋯]` opens SwiftUI `ColorPicker`
  (system Colors panel) for arbitrary hex. Auto-assign the next unused palette
  color on create so a color always exists; override anytime. Persist as hex.

---

## 2. Integration — collection as a cross-app *lens*, not a hidden tab

The fix for "won't get used." One new core primitive, then chips + a global
scope. All three reuse the same once-per-scan caching seam as `cachedAllRows`.

### New primitive: reverse membership index
`CollectionResolver` only goes id → `Set<path>`. Add
`membership(of paths:, collections:, knownPaths:) -> [String: [collectionID]]`
(invert `resolveAll`). Build once per scan tick; thread down. This feeds chips.

### Collection chips (provenance everywhere)
Reuse the existing `Chip` component tinted with `pacerCollectionColor(seed:)`:
- **Projects table row** (`ProjectsView.projectRow`, under the path subline) —
  highest value.
- **Project-detail header**, **day-detail rows**, **collection member rows**
  (show only *other* memberships there).
- Space-constrained surfaces (sessions table, Now tile): a single overflow
  chip ("2 collections") or skip.
- Tap a chip → set the global scope (below).

### "Add to collection…" context menu
A sibling to the existing "Merge into…" (`ProjectsView.mergeIntoMenu`,
`ProjectDetailView.mergeMenuButton`) — lists collections (hue dot) + "New
collection from this project…". Mutation factored into a tiny
`CollectionsMutator.addProject(_:to:)` in PacerCore, shared with the editor.
Verb + visual language stays distinct from the destructive Merge.

### Global "scope to collection" filter
One shared `@AppStorage("pacer.scope.collectionID", store: PacerSettings.store)`.
A toolbar selector (`ContentView` primary-action slot) + optionally a sidebar
section; chip-taps set the same key (two doors, one state). Resolve id →
`Set<path>` where each view already has `aggregates`.

**Honesty boundary — not every view can scope (this matters):**
- **Projects** scopes cleanly (one `where members.contains(projectPath)` in
  `computeAllRowsSync`). Ship first.
- **History** scopes only with re-derivation (it reads account-level
  `DailyAggregate`, not per-project) — phase 2.
- **Dashboard pace / rate-limit / Now burn** are **account-global and cannot
  be scoped** — rate limits have no per-project decomposition. These stay
  account-wide with an explicit "pacing is account-wide" caveat. **Never
  silently ignore the scope** — a wrong-looking number is worse than none.

Scope × the existing per-tab range picker is a 2-D filter; keep both, label
clearly.

---

## 3. Per-project color — new `ProjectMeta` model

There's no per-project color today (the donut uses Swift Charts' categorical
scale by display-name; the legend uses positional `legendColor(idx)` — two
different systems, both shuffle by rank). Add, modeled exactly on
`ProjectBudget` (one sparse row per project, additive, no store reset):

```swift
@Model final class ProjectMeta {
    @Attribute(.unique) var projectPath: String   // canonical, post-alias
    var colorHex: String?                          // nil = auto/positional
    var updatedAt: Date
}
```

Register in `PacerStore.allModelTypes`. Color well in the project-detail
modal (next to the budget editor; same insert-on-set / delete-on-clear shape).
- **Bonus:** once it exists, donut + legend can resolve through one per-path
  color map (stored hex, else stable hash-of-path) — fixing the latent
  donut/legend mismatch and giving every project a stable color. Per the
  shared-views rule, treat the donut recolor as a **separate flagged change**,
  not a silent side effect.
- **Risks:** key on the **canonical** path (or a merge drops the color — hook
  the same re-attribution pass that rewrites `ProjectBudget`); clamp luminance
  so arbitrary user hex stays legible on chips/donut in light + dark.

---

## Build phasing

1. **Editor redesign** — folder-picker rules + live previews + multi-rule,
   staged-folder picker, disambiguated rows, color swatches. (Fixes "hard to
   use / opaque rules / can't pre-tag / ambiguous names / collection color.")
2. **Disambiguation helper** — app-wide, used by editor *and* the projects
   table (standalone win even outside collections).
3. **Integration phase A** — reverse membership index + chips on the projects
   table + "Add to collection…" menu + global scope for the **Projects** tab.
4. **Per-project color** — `ProjectMeta` + project color well (+ flagged
   donut/legend unification).
5. **Integration phase B** — scope History (re-derived); pace/rate-limit stays
   account-wide with caveat. Chips on more surfaces.
6. Re-evaluate the **lane vs tree** bake-off with real data; trim the loser.
   Then README screenshots + cut the release (additive/patch).

## Open decisions (need sign-off)

- **Integration depth this pass:** full cross-app lens (phases 3+5) vs.
  editor + Projects-tab only for now.
- **Per-project colors:** in scope now (`ProjectMeta`) vs collections-only.
- **Globs:** folder-picker-first + globs-as-flagged-advanced (recommended) vs
  implement globs now vs folder-only forever.
