import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// The account scope, in the window toolbar.
///
/// It governs every view, not one card, so it belongs in window chrome — and
/// it sits beside the title bar's "5h 23% • 7d 41%" subtitle, which is the
/// *active* account's, so the account context is next to the numbers it
/// qualifies. It was previously a menu inside the Accounts card, where the
/// maintainer did not notice it existed.
///
/// **A popover, not a `Menu`.** SwiftUI's menu popups render detached and
/// mis-scaled at a screen corner in this app — reported on both a `Picker` in
/// Settings and the card's own `Menu`, so it is not specific to either.
/// `NSPopover` is positioned by a different path and does not exhibit it. The
/// underlying menu problem is still open; this control avoids depending on it.
///
/// Hidden entirely with one account.
struct ToolbarAccountScope: View {
    @Query(ToolbarAccountScope.accountsDescriptor) private var accounts: [Account]
    @State private var scope = UsageScope.shared
    @State private var showing = false

    private static let accountsDescriptor: FetchDescriptor<Account> = {
        FetchDescriptor<Account>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
    }()

    var body: some View {
        if accounts.count > 1 {
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.system(size: 10, weight: .medium))
                    Text(label)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(scope.isAll ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Which account the spend and token views show")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                picker
            }
        }
    }

    private var label: String {
        guard let id = scope.accountId else { return "All accounts" }
        return accounts.first { $0.id == id }?.label ?? "All accounts"
    }

    /// Shares `PacerChoiceList` with `PacerSelect` so the rows behave
    /// identically; only the trigger differs, because a toolbar control has
    /// to be compact where a form field should look like a field.
    private var picker: some View {
        PacerChoiceList(
            options: [.init(value: nil as String?, title: "All accounts")]
                + accounts.map {
                    .init(value: $0.id as String?, title: $0.label,
                          detail: $0.subscriptionType)
                },
            isSelected: { $0 == scope.accountId },
            onPick: { id in
                scope.select(id)
                showing = false
            }
        )
        .frame(width: 260)
    }
}
