import SwiftUI
import PacerCore

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
    /// Whatever the calling screen needs on the right: an Active badge, a
    /// Switch button, a turn count.
    public let trailing: () -> Trailing

    public init(model: Model, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.model = model
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
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

            HStack(spacing: 10) {
                PacerWindowReadout(label: "5h", percent: model.fiveHourPercent)
                PacerWindowReadout(label: "7d", percent: model.sevenDayPercent)
            }

            trailing()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
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
}

/// One rate-limit window as a label and a percentage, coloured by
/// `UsageBand` — the app's single definition of what a percentage means.
public struct PacerWindowReadout: View {
    public let label: String
    public let percent: Double?

    public init(label: String, percent: Double?) {
        self.label = label
        self.percent = percent
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(percent.map { UsageBand(percentage: $0).color } ?? .secondary)
        }
        .frame(width: 52, alignment: .leading)
    }
}
