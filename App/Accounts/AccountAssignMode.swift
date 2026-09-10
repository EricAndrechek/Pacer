import Foundation
import PacerCore
import SwiftData

/// Headless mode for assigning historical usage to an account.
///
/// Pacer attributes new turns automatically once it has watched a login, but
/// history written before that has no account and cannot get one from the
/// transcripts — see `AccountActivation`. A store with exactly one known
/// account backfills itself; a store with several can only be told.
///
/// Two accounts is the case with no sound inference available, so this is
/// where the user supplies the missing fact. It runs against the real store,
/// which means Pacer must not be running — `make assign-accounts` handles the
/// quit/restart, the same way `verify-archive` does.
///
///     PACER_ACCOUNT_ASSIGN=list
///     PACER_ACCOUNT_ASSIGN='<accountId>|<from>|<through>[;<accountId>|…]'
///
/// `from`/`through` are ISO-8601 instants, or `-` for open-ended. Ranges are
/// half-open — `[from, through)` — so consecutive ranges can share a boundary
/// without double-claiming the instant on it.
enum AccountAssignMode {
    static var isActive: Bool { spec != nil }

    private static var spec: String? {
        let raw = ProcessInfo.processInfo.environment["PACER_ACCOUNT_ASSIGN"]
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    @MainActor
    static func run(container: ModelContainer) async {
        await perform(container: container)
    }

    /// All of this runs on `@ScanActor`: `AccountBackfill` is isolated to it,
    /// and a `ModelContext` is thread-affine, so it has to be born on the
    /// actor that uses it — the same rule the scan pipeline follows.
    @ScanActor
    private static func perform(container: ModelContainer) async {
        guard let spec else { return }
        let context = ModelContext(container)

        if spec == "list" {
            report(context: context)
            return
        }

        for clause in spec.split(separator: ";") {
            let parts = clause.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, !parts[0].isEmpty else {
                print("assign: malformed clause '\(clause)' — expected <accountId>|<from>|<through>")
                continue
            }
            let accountId = parts[0]
            guard let from = parseBound(parts[1]), let through = parseBound(parts[2]) else {
                print("assign: unparseable date in '\(clause)' — use ISO-8601 or '-'")
                continue
            }
            let fromDate = from.date
            let throughDate = through.date
            do {
                let result = try AccountBackfill.assign(
                    accountId: accountId,
                    from: fromDate,
                    through: throughDate,
                    context: context,
                    evidence: "assigned by the maintainer via PACER_ACCOUNT_ASSIGN"
                )
                print("assign: \(result.samplesAttributed) sample(s) → \(accountId) "
                      + "[\(describe(fromDate)) … \(describe(throughDate)))")
            } catch {
                print("assign: failed for \(accountId): \(error)")
            }
        }

        report(context: context)
    }

    /// One end of a range: deliberately three-valued, so "no bound" and
    /// "bad input" stay distinguishable. Collapsing them would let a typo
    /// become an unbounded range that silently claims all of history.
    private enum Bound {
        case open
        case at(Date)
        var date: Date? {
            if case .at(let d) = self { return d }
            return nil
        }
    }

    /// `-` means open-ended; anything else must parse as ISO-8601.
    /// Returns nil — not `.open` — when the input is unparseable.
    private static func parseBound(_ raw: String) -> Bound? {
        if raw == "-" || raw.isEmpty { return .open }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return .at(d) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return .at(d) }
        return nil
    }

    private static func describe(_ date: Date?) -> String {
        guard let date else { return "-" }
        return ISO8601DateFormatter().string(from: date)
    }

    @ScanActor
    private static func report(context: ModelContext) {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        print("accounts known to Pacer:")
        for account in accounts {
            let marker = account.isActive ? "*" : " "
            print("  \(marker) \(account.id)  \(account.displayName)")
        }
        if let summary = try? AccountBackfill.unattributedSummary(context: context) {
            if summary.count == 0 {
                print("every turn is attributed to an account")
            } else {
                print("unattributed: \(summary.count) turn(s) "
                      + "[\(describe(summary.earliest)) … \(describe(summary.latest))]")
            }
        }
        let spans = (try? context.fetch(FetchDescriptor<AccountActivation>(
            sortBy: [SortDescriptor(\.startedAt)]))) ?? []
        if !spans.isEmpty {
            print("activation trail:")
            for span in spans {
                print("  \(describe(span.startedAt)) … \(describe(span.endedAt))  "
                      + "\(span.accountId)  (\(span.source))")
            }
        }
    }
}
