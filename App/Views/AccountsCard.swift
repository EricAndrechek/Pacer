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
/// Rows come from `PacerAccountRow`, the same component the Tokens settings
/// switcher uses. They were two hand-rolled layouts showing the same facts,
/// which is how they ended up disagreeing about what colour 60% is.
///
/// **Renders nothing with one account.** A roster of one repeats what the rest
/// of the dashboard already says.
struct AccountsCard: View {
    @Query(AccountsCard.accountsDescriptor) private var accounts: [Account]
    @State private var totals = AccountTotalsStatus.shared
    @State private var scope = UsageScope.shared

    private static let accountsDescriptor: FetchDescriptor<Account> = {
        FetchDescriptor<Account>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
    }()

    var body: some View {
        if accounts.count > 1 {
            PacerCard("Accounts") {
                VStack(spacing: 4) {
                    ForEach(sortedAccounts, id: \.id) { account in
                        PacerAccountRow(model: .init(
                            name: account.label,
                            plan: account.subscriptionType,
                            subtitle: subtitle(for: account),
                            fiveHourPercent: account.latestFiveHourPct,
                            sevenDayPercent: account.latestSevenDayPct,
                            isActive: account.isActive
                        )) {
                            if account.isActive {
                                Text("Active")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.green.opacity(0.16)))
                            }
                        }
                    }
                }
            } footer: {
                Text(scopeNote)
            }
        }
    }

    private var sortedAccounts: [Account] {
        accounts.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    private func subtitle(for account: Account) -> String? {
        guard let totals = totals.totals.first(where: { $0.accountId == account.id }),
              totals.turns > 0
        else { return nil }
        var parts = ["\(totals.turns.formatted()) turns"]
        if let first = totals.firstTurnAt, let last = totals.lastTurnAt {
            parts.append(Calendar.current.isDate(first, inSameDayAs: last)
                ? Self.dayMonth(last)
                : "\(Self.dayMonth(first)) – \(Self.dayMonth(last))")
        }
        return parts.joined(separator: " · ")
    }

    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    private static func dayMonth(_ date: Date) -> String {
        dayMonthFormatter.string(from: date)
    }

    /// Which account the spend and token cards are showing. The control that
    /// changes it lives in the toolbar — it governs every view, so it belongs
    /// in window chrome rather than inside one card.
    private var scopeNote: String {
        let shown = scope.isAll
            ? "all accounts"
            : (accounts.first { $0.id == scope.accountId }?.label ?? "all accounts")
        var note = "Limits are per account. Spend and tokens below show \(shown)."
        if let orphan = totals.unattributed, orphan.turns > 0 {
            note += " \(orphan.turns.formatted()) turns predate account tracking."
        }
        return note
    }
}
