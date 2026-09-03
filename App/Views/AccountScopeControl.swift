import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Which account the spend and token views show.
///
/// **A segmented control, not a popup.** Every popup mechanism in this app
/// currently mis-anchors — SwiftUI menus render into a screen corner, and a
/// `.popover` attached to a `ToolbarItem` opens against the window's leading
/// edge rather than the button. A segmented control has no popup at all, and
/// the seven already in the app behave correctly, so the scope switch does not
/// have to wait on that bug being understood.
///
/// It lives in the page header rather than the window toolbar for the same
/// reason: the toolbar is where the popover anchoring failed, and a header
/// control sits with the page's own title and subtitle where it reads as
/// qualifying them.
///
/// Renders nothing with one account.
struct AccountScopeControl: View {
    @Query(AccountScopeControl.accountsDescriptor) private var accounts: [Account]
    @State private var scope = UsageScope.shared

    private static let accountsDescriptor: FetchDescriptor<Account> = {
        FetchDescriptor<Account>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
    }()

    /// Beyond this, segments stop being readable and the control would need a
    /// popup — which is exactly what is broken. Falls back to showing the
    /// current scope as plain text until that is fixed.
    private static let maxSegments = 4

    var body: some View {
        if accounts.count > 1 {
            if accounts.count + 1 <= Self.maxSegments {
                Picker("Account", selection: binding) {
                    Text("All").tag(nil as String?)
                    ForEach(accounts, id: \.id) { account in
                        Text(Self.shortLabel(account.label)).tag(account.id as String?)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Which account the spend and token cards show")
            } else {
                Text(currentLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var binding: Binding<String?> {
        Binding(get: { scope.accountId }, set: { scope.select($0) })
    }

    private var currentLabel: String {
        guard let id = scope.accountId else { return "All accounts" }
        return accounts.first { $0.id == id }.map { Self.shortLabel($0.label) } ?? "All accounts"
    }

    /// Segments have to stay narrow, and an email's local part is what
    /// distinguishes two accounts far more often than its domain.
    static func shortLabel(_ label: String) -> String {
        guard let at = label.firstIndex(of: "@") else { return label }
        return String(label[label.startIndex..<at])
    }
}
