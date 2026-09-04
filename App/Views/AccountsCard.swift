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
    @Environment(\.modelContext) private var modelContext
    /// Whether the accounts are ever used at the same time — the same test
    /// `PaceChartCard` uses to decide whether "all accounts" draws one set of
    /// limit cards or every account's. See `AccountParallelism`.
    @State private var isParallel = false

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
            .task { refreshParallelism() }
            .onChange(of: scope.accountId) { _, _ in refreshParallelism() }
            .onReceive(NotificationCenter.default.publisher(for: .pacerScanCycleDidComplete)) { _ in
                refreshParallelism()
            }
        }
    }

    private func refreshParallelism() {
        isParallel = AccountParallelism.isParallel(context: modelContext)
    }

    /// The switcher's order when there is one, so the list matches the tool the
    /// user actually switches with. See `Account.listOrder`.
    private var sortedAccounts: [Account] {
        accounts.sorted(by: Account.listOrder)
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

    /// What the cards below this one are showing. The control that changes it
    /// lives in the toolbar — it governs every view, so it belongs in window
    /// chrome rather than inside one card.
    ///
    /// Spend and limits answer the scope differently and the note has to say
    /// so: costs from two accounts add up, two 5-hour windows do not. Under
    /// "all accounts" the pace cards therefore show either every account's
    /// windows side by side (when the accounts run in parallel) or just the
    /// active login's. The note used to say a flat "Limits are per account",
    /// which was true of the world and told you nothing about the screen.
    private var scopeNote: String {
        var note: String
        if let picked = accounts.first(where: { $0.id == scope.accountId }) {
            note = "Spend, tokens and limits below show \(picked.label)."
        } else if isParallel {
            note = "Spend and tokens below cover all accounts; limits are shown per account."
        } else {
            let live = accounts.first { $0.id == scope.limitAccountId }?.label
            note = live.map {
                "Spend and tokens below cover all accounts; limits show \($0)."
            } ?? "Spend and tokens below cover all accounts."
        }
        if let orphan = totals.unattributed, orphan.turns > 0 {
            note += " \(orphan.turns.formatted()) turns predate account tracking."
        }
        return note
    }
}
