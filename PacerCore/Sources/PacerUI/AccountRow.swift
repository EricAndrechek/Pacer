import SwiftUI
import PacerCore

/// What to do with a new name, as a value rather than a bare closure.
///
/// Not `((String) -> Void)?` on purpose. Swift matches an unlabelled trailing
/// closure to the *first* parameter that can structurally accept one, so an
/// optional closure parameter declared before `trailing` silently swallows
/// every existing `PacerAccountRow(model:) { badge }` call site — which is how
/// this was first written, and it failed to build in a way that pointed at the
/// caller rather than the cause. A struct cannot be mistaken for the trailing
/// closure, so callers that do not rename need to know nothing about this.
public struct PacerRenameAction {
    public let perform: (String) -> Void
    public init(_ perform: @escaping (String) -> Void) { self.perform = perform }
}

/// One account, rendered the same way everywhere.
///
/// There were two of these: the Tokens settings switcher and the dashboard's
/// Accounts card, showing the same facts — name, plan, 5h and 7d utilisation —
/// in two hand-rolled layouts. Worse than the visual drift, the settings copy
/// carried its own colour thresholds (`>=85` red, `>=50` orange, else green)
/// which disagree with `UsageBand` in the 50–75 band: 60% rendered orange in
/// Settings and yellow on the dashboard. The same number, two colours,
/// depending which screen you were on.
///
/// So this is the one implementation, and it uses `UsageBand` — the app's
/// canonical mapping — rather than a local approximation of it.
///
/// Deliberately takes a plain value rather than `Account` or
/// `AccountStatusSummary`: PacerUI must not depend on which of those a given
/// screen happens to hold, or the sharing breaks again the first time a third
/// caller has neither.
public struct PacerAccountRow<Trailing: View>: View {
    public struct Model: Equatable {
        public let name: String
        /// Plan or subscription tier, shown beside the name when known.
        public let plan: String?
        /// One quiet line under the name — token count, org tail, date range.
        public let subtitle: String?
        public let fiveHourPercent: Double?
        public let sevenDayPercent: Double?
        public let isActive: Bool

        public init(
            name: String, plan: String? = nil, subtitle: String? = nil,
            fiveHourPercent: Double? = nil, sevenDayPercent: Double? = nil,
            isActive: Bool = false
        ) {
            self.name = name
            self.plan = plan
            self.subtitle = subtitle
            self.fiveHourPercent = fiveHourPercent
            self.sevenDayPercent = sevenDayPercent
            self.isActive = isActive
        }
    }

    public let model: Model
    /// Non-nil makes the name editable in place — double-click it, or use the
    /// row's context menu. Called with the trimmed new name; an empty string
    /// means "clear the rename", which the caller turns back into whatever
    /// name it would have derived.
    ///
    /// It lives on the shared row rather than in one screen because both
    /// screens show the same name, and the last time these two rows were
    /// implemented separately they drifted apart. A screen that has nothing
    /// to write passes nil and gets plain text.
    public let onRename: PacerRenameAction?
    /// Whatever the calling screen needs on the right: an Active badge, a
    /// Switch button, a turn count.
    public let trailing: () -> Trailing

    @State private var draft = ""
    @State private var isRenaming = false
    @FocusState private var nameFocused: Bool

    public init(model: Model, onRename: PacerRenameAction? = nil,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.model = model
        self.onRename = onRename
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isRenaming {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: 180)
                            .focused($nameFocused)
                            .onSubmit(commitRename)
                            .onExitCommand { isRenaming = false }
                            // Clicking elsewhere is a commit, not a discard:
                            // the field looks like the name it replaced, so
                            // losing the edit would read as the rename having
                            // silently failed.
                            .onChange(of: nameFocused) { _, focused in
                                if !focused && isRenaming { commitRename() }
                            }
                    } else {
                        Text(model.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture(count: 2) { beginRename() }
                    }
                    if let plan = model.plan, !plan.isEmpty {
                        Text(plan)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                PacerWindowReadout(label: "5h", percent: model.fiveHourPercent)
                PacerWindowReadout(label: "7d", percent: model.sevenDayPercent)
            }

            // Fixed width so the readouts line up between rows: a row with an
            // "Active" badge must not push its percentages left of a row
            // without one.
            //
            // The `Color.clear` is load-bearing. A caller writes
            // `if isActive { Text("Active") }`, which yields a *nil* view for
            // an inactive row — and a nil view occupies no space no matter
            // what `.frame` is applied to it, so sizing `trailing()` directly
            // silently did nothing. The ZStack always has a child that takes
            // the full width.
            ZStack(alignment: .trailing) {
                Color.clear
                trailing()
            }
            .frame(width: 62)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .contextMenu {
            if onRename != nil {
                Button("Rename…") { beginRename() }
                Button("Reset Name") { onRename?.perform("") }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(model.isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            model.isActive ? Color.accentColor.opacity(0.35) : Color.clear,
                            lineWidth: 1)
                )
        )
    }

    private func beginRename() {
        guard onRename != nil else { return }
        draft = model.name
        isRenaming = true
        nameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.name else { return }
        onRename?.perform(trimmed)
    }
}

/// One rate-limit window as a label and a percentage, coloured by
/// `UsageBand` — the app's single definition of what a percentage means.
/// One rate-limit window: label, a bar, and the number.
///
/// The bar carries one encoding only — length is utilisation, colour is the
/// `UsageBand` that utilisation falls in. Nothing else is folded in, so it
/// cannot say two things at once.
///
/// The label is `.secondary` rather than `.tertiary`: tertiary on a dark card
/// sits well under the contrast Apple's own guidance asks for, and these are
/// the only thing telling you which window a number belongs to.
public struct PacerWindowReadout: View {
    public let label: String
    public let percent: Double?

    private static let barWidth: CGFloat = 44

    public init(label: String, percent: Double?) {
        self.label = label
        self.percent = percent
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: Self.barWidth, height: 4)
                .overlay(alignment: .leading) {
                    if let percent {
                        Capsule()
                            .fill(UsageBand(percentage: percent).color)
                            .frame(
                                width: max(2, Self.barWidth * min(1, percent / 100)),
                                height: 4)
                    }
                }
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(percent.map { UsageBand(percentage: $0).color } ?? .secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
