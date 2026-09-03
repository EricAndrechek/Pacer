import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Every account Pacer knows about, one row each.
///
/// Exists because the live sample tables hold one account's timeline by
/// construction, so "how close is my other account to its weekly cap" had no
/// answer anywhere in the app.
///
/// **Renders nothing with one account.** A roster of one repeats what the
/// rest of the dashboard already says.
struct AccountsCard: View {
    @Query(AccountsCard.accountsDescriptor) private var accounts: [Account]
    @State private var totals = AccountTotalsStatus.shared
    @State private var scope = UsageScope.shared

    private static let accountsDescriptor: FetchDescriptor<Account> = {
        FetchDescriptor<Account>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
    }()

    var body: some View {
        if accounts.count > 1 {
            PacerCard("Accounts", trailing: { scopePicker }) {
                VStack(spacing: 0) {
                    ForEach(Array(sortedAccounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().opacity(0.3) }
                        AccountRow(
                            account: account,
                            turns: totals.totals.first { $0.accountId == account.id }?.turns
                        )
                        .padding(.vertical, 7)
                    }
                }
            } footer: {
                // Scope, stated once. The pace chart above is the active
                // account's; every cost and token rollup predates accounts
                // and has no account dimension, so it sums all of them.
                Text(scopeNote)
            }
        }
    }

    /// Which account the spend and token cards below are showing.
    ///
    /// A menu rather than a segmented control: the label has to be an email
    /// address, and segments sized for those stop being compact at two
    /// accounts and stop fitting at three.
    private var scopePicker: some View {
        Menu {
            Button { scope.select(nil) } label: {
                Label("All accounts", systemImage: scope.isAll ? "checkmark" : "")
            }
            Divider()
            ForEach(sortedAccounts, id: \.id) { account in
                Button { scope.select(account.id) } label: {
                    Label(account.label,
                          systemImage: scope.accountId == account.id ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(scopeLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var scopeLabel: String {
        guard let id = scope.accountId else { return "All accounts" }
        return accounts.first { $0.id == id }?.label ?? "All accounts"
    }

    private var sortedAccounts: [Account] {
        accounts.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    private var scopeNote: String {
        var note = scope.isAll
            ? "Limits are per account. Spend and tokens below combine all."
            : "Limits are per account. Spend and tokens below show \(scopeLabel)."
        if let orphan = totals.unattributed, orphan.turns > 0 {
            note += " \(orphan.turns.formatted()) turns predate account tracking."
        }
        return note
    }
}

/// One account on one line: identity left, limits and volume right.
private struct AccountRow: View {
    let account: Account
    let turns: Int?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(account.isActive ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)

            Text(account.label)
                .font(.system(size: 12, weight: account.isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(account.isActive ? .primary : .secondary)

            Spacer(minLength: 12)

            if let turns {
                Text(turns.formatted())
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help("\(turns.formatted()) turns recorded")
            }

            WindowMeter(label: "5h",
                        percent: account.latestFiveHourPct,
                        resetsAt: account.latestFiveHourResetsAt)
            WindowMeter(label: "7d",
                        percent: account.latestSevenDayPct,
                        resetsAt: account.latestSevenDayResetsAt)
        }
    }
}

/// One rate-limit window: a bar and its number.
///
/// One encoding per bar — length is utilisation, colour is the band it falls
/// in — so the bar can never say two things at once.
private struct WindowMeter: View {
    let label: String
    let percent: Double?
    let resetsAt: Date?

    private static let barWidth: CGFloat = 46

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            if let percent {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: Self.barWidth, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(UsageBand(percentage: percent).color)
                            .frame(width: max(2, Self.barWidth * min(1, percent / 100)), height: 4)
                    }
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.barWidth + 35, alignment: .trailing)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        guard let resetsAt else { return "\(label) window" }
        return "\(label) resets \(pacerRelative(resetsAt))"
    }
}
