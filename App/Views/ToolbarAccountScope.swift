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

    private var picker: some View {
        VStack(alignment: .leading, spacing: 2) {
            choice(name: "All accounts", plan: nil, selected: scope.isAll) {
                scope.select(nil)
            }
            Divider().padding(.vertical, 2)
            ForEach(accounts, id: \.id) { account in
                choice(name: account.label,
                       plan: account.subscriptionType,
                       selected: scope.accountId == account.id) {
                    scope.select(account.id)
                }
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    private func choice(
        name: String, plan: String?, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            showing = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}
