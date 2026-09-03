import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Every account Pacer knows about, side by side.
///
/// The card exists because until now there was nowhere to see a second
/// account at all. The live sample tables hold one account's timeline — the
/// active one — so every other card on this dashboard describes whoever is
/// currently logged in, and says nothing about the account you are not using.
///
/// **Only shown when there is more than one account.** A single-account user
/// gains nothing from a roster of one and should see no new chrome; the
/// numbers here would just repeat what the rest of the dashboard already
/// says.
struct AccountsCard: View {
    @Query(AccountsCard.accountsDescriptor) private var accounts: [Account]
    @State private var totals = AccountTotalsStatus.shared

    private static let accountsDescriptor: FetchDescriptor<Account> = {
        FetchDescriptor<Account>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
    }()

    var body: some View {
        if accounts.count > 1 {
            PacerCard("Accounts") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sortedAccounts, id: \.id) { account in
                        AccountRow(account: account, totals: totals.totals.first {
                            $0.accountId == account.id
                        })
                        if account.id != sortedAccounts.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            } footer: {
                footerText
            }
        }
    }

    /// Active first, then most recently seen. The account you are spending
    /// on is the one you are looking for.
    private var sortedAccounts: [Account] {
        accounts.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    @ViewBuilder
    private var footerText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("The rest of this dashboard shows the active account — the one Claude Code will bill your next message to. Pacer follows your login.")
            Text("Per-account cost isn't here yet: every cost rollup predates accounts, so splitting spend needs a per-account rollup rather than a walk over every turn.")
            if let unattributed = totals.unattributed, unattributed.turns > 0 {
                // Deliberately phrased as missing coverage rather than as an
                // account called "unknown". These turns are real usage whose
                // account was never recorded and cannot be recovered — see
                // `AccountActivation` — so presenting them as a third account
                // would invent an entity that never existed.
                Text("\(unattributed.turns.formatted()) turns from before Pacer tracked accounts aren't attributed to either.")
            }
        }
    }
}

/// One account: who it is, how close it is to its limits, and what it has
/// cost.
private struct AccountRow: View {
    let account: Account
    let totals: AccountTotals?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if account.isActive {
                    Chip(text: "ACTIVE", tint: .accentColor, size: .compact)
                }
                Spacer(minLength: 8)
                if let subscription = account.subscriptionType, !subscription.isEmpty {
                    Text(subscription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 16) {
                WindowMeter(label: "5h",
                            percent: account.latestFiveHourPct,
                            resetsAt: account.latestFiveHourResetsAt)
                WindowMeter(label: "7d",
                            percent: account.latestSevenDayPct,
                            resetsAt: account.latestSevenDayResetsAt)
            }

            if let totals, totals.turns > 0 {
                Text(summary(totals))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Distinguishes "not measured yet" from "no usage", which is
                // why `computedAt` exists.
                Text("No usage recorded yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func summary(_ t: AccountTotals) -> String {
        var parts = ["\(t.turns.formatted()) turns"]
        if let first = t.firstTurnAt, let last = t.lastTurnAt {
            parts.append(Calendar.current.isDate(first, inSameDayAs: last)
                ? Self.dayMonth(last)
                : "\(Self.dayMonth(first)) – \(Self.dayMonth(last))")
        }
        return parts.joined(separator: " · ")
    }

    /// "3 Sep" — short enough to sit inline with three other facts, and
    /// unambiguous without a year for a range this view can show.
    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    private static func dayMonth(_ date: Date) -> String {
        dayMonthFormatter.string(from: date)
    }

}

/// One rate-limit window as a single bar plus its number.
///
/// One encoding per bar: length is utilisation, colour is the band that
/// utilisation falls in. Nothing else is folded in, so the bar cannot say two
/// things at once.
private struct WindowMeter: View {
    let label: String
    let percent: Double?
    let resetsAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .leading)
            if let percent {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 64, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(UsageBand(percentage: percent).color)
                            .frame(width: max(2, 64 * min(1, percent / 100)), height: 5)
                    }
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        guard let resetsAt else { return "\(label) window" }
        return "\(label) window resets \(pacerRelative(resetsAt))"
    }
}
