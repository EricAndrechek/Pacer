import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Which account the spend and token views show.
///
/// A native `Menu`. It was briefly a segmented control and then a hand-rolled
/// popover, because menus were opening in a screen corner — but that was
/// never the menu's fault: `MainWindowPlacement.holdPlacement` was scheduling
/// `setFrame` calls from `didBecomeKey`, so clicking the control moved the
/// window out from under the anchor the menu had already resolved. Replacing
/// the control was treating the symptom.
///
/// Renders nothing with one account.
struct AccountScopeControl: View {
    @Query(AccountScopeControl.accountsDescriptor) private var accounts: [Account]
    @State private var scope = UsageScope.shared

    private static let accountsDescriptor: FetchDescriptor<Account> = {
        FetchDescriptor<Account>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
    }()

    var body: some View {
        if accounts.count > 1 {
            Menu {
                Picker("Account", selection: binding) {
                    Text("All accounts").tag(nil as String?)
                    // The switcher's slot order when there is one, so this
                    // menu reads in the same order as `cswap list`.
                    ForEach(accounts.sorted(by: Account.listOrder), id: \.id) { account in
                        // The account Claude Code is signed into is marked here
                        // as well as on the pace card. This menu is where you
                        // *choose* an account, so it is where "which one am I
                        // actually on?" gets asked — and the two are easy to
                        // confuse when a switcher changes the answer without
                        // telling you.
                        Text(account.isActive
                             ? "\(account.label)  ·  signed in"
                             : account.label)
                            .tag(account.id as String?)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(label, systemImage: "person.2")
            }
            .help("Which account the spend and token views show")
        }
    }

    private var binding: Binding<String?> {
        Binding(get: { scope.accountId }, set: { scope.select($0) })
    }

    /// The toolbar's own text. Under "all accounts" it names the signed-in
    /// login rather than saying nothing, because that is the one whose limits
    /// the terminal is reporting and the question people actually have.
    private var label: String {
        guard let id = scope.accountId else {
            guard let active = accounts.first(where: { $0.isActive }) else {
                return "All accounts"
            }
            return "All · on \(active.shortLabel)"
        }
        return accounts.first { $0.id == id }?.label ?? "All accounts"
    }
}
