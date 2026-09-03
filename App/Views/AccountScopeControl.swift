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
                    ForEach(accounts, id: \.id) { account in
                        Text(account.label).tag(account.id as String?)
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

    private var label: String {
        guard let id = scope.accountId else { return "All accounts" }
        return accounts.first { $0.id == id }?.label ?? "All accounts"
    }
}
