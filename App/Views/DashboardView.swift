import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Primary view a user sees when opening Pacer, ordered by immediacy:
///
///   1. Welcome banner (auto-hidden once any data lands).
///   2. Now strip — Live (last-hour burn) + Today (spend, outlook, budget).
///   3. PaceChart card (full width, the two big 5h/7d charts with their
///      status + burn chips).
///   4. Today's breakdowns, weekly comparison, 30-day cost, month outlook.
///
/// Each card is its own `View` and owns its own `@Query` so SwiftData
/// updates stay incremental: a new TokenSample only invalidates the
/// cards that read TokenSample/DailyAggregate, not the rate-limit charts.
struct DashboardView: View {
    /// Read here, not inside each card, so a scope change re-runs their
    /// initialisers — a `@Query` predicate is captured once at init.
    @State private var scope = UsageScope.shared

    @State private var modalRoot: PacerModalDestination?

    var body: some View {
        // Read in this body and captured below, not read inside
        // `PageScaffold`'s stored closures. See `ProjectsView.body` (#140).
        let scopeAccountId = scope.accountId, limitAccountId = scope.limitAccountId
        PageScaffold(
            "Dashboard",
            subtitle: "Realtime view of your Claude Code usage.",
            // Eager stack: the dashboard is a small, fixed set of cards the
            // user scrolls through anyway, so realizing them all up front
            // (rather than lazily as each crosses the viewport) removes the
            // per-card render-on-appear that made scrolling past the chart
            // cards stutter. The @Query fanout this re-incurs is mitigated
            // by the cards' gated caches + the EquatableView work (#102/#105).
            lazy: false,
            // Notice badges + the data-source freshness chip live in the
            // header's trailing slot — zero vertical pixels, and both
            // describe the page as a whole rather than any one card.
            trailing: {
                // AdvisorBadges owns the whole header strip now — the notices
                // *and* the data-source chip flow together in one wrapping
                // layout, so they spill to a tidy second row when several fire.
                AdvisorBadges(scopeAccountId: scopeAccountId)
                    .layoutShiftProbe("header")
            }
        ) {
            WelcomeCard().layoutShiftProbe("welcome")
            DesktopCredentialPrompt().layoutShiftProbe("desktop-prompt")
            NowStrip(
                onTodayTap: openToday,
                onSessionTap: { sessionId, displayName in
                    modalRoot = .session(sessionId: sessionId, projectDisplayName: displayName)
                }
            )
            .layoutShiftProbe("now-strip")
            // Pace charts for EVERY rate-limit window — the fixed 5h/7d blocks
            // and each scoped per-model window (e.g. a "Fable" weekly cap) as
            // first-class, identically-treated columns. `window` is the fixed
            // window name or the scoped `limits[]` identity; the projection
            // modal accepts both.
            PaceChartCard(limitAccountId: limitAccountId, onCompare: { window, account in
                modalRoot = .projection(window: window, accountId: account)
            })
            .layoutShiftProbe("pace")
            // Directly under the pace chart, because it answers the question
            // that chart raises the moment a second account exists: whose
            // numbers am I looking at? Renders nothing at all for a
            // single-account user, which is almost everyone.
            TodayDetailsCard(scopeAccountId: scopeAccountId)
                .layoutShiftProbe("today-details")
            TodayTimelineCard(onTodayTap: openToday, scopeAccountId: scopeAccountId)
                .layoutShiftProbe("today-timeline")
            PerModelTodayCard(scopeAccountId: scopeAccountId)
                .layoutShiftProbe("per-model")
            WeeklyComparisonCard(scopeAccountId: scopeAccountId)
                .layoutShiftProbe("weekly")
            DailyCostChartCard(scopeAccountId: scopeAccountId, onDayTap: { dayKey in
                modalRoot = .day(date: dayKey)
            })
            .layoutShiftProbe("daily-cost")
            MonthOutlookCard(scopeAccountId: scopeAccountId)
                .layoutShiftProbe("month-outlook")
        }
        .pacerModalNavigation(modalRoot, root: $modalRoot)
    }

    /// Open today's day-detail modal. Pinned to the user's local
    /// timezone via TokenSample.formatDate so the date key matches
    /// what aggregates actually store under.
    private func openToday() {
        let today = TokenSample.formatDate(Date())
        modalRoot = .day(date: today)
    }
}

// MARK: - Header freshness chip

/// "via oauth · just now" — the rate-limit data-source freshness signal,
/// in the page header because it describes the whole dashboard rather
/// than one card. Goes yellow with a warning triangle when an OAuth feed
/// stalls past 15 minutes — commonly an expired Claude Code token.
struct RateLimitSourceChip: View {
    let limitAccountId: String?

    /// `@State` + a keyed fetch rather than `@Query`.
    ///
    /// It has to be scoped: `fetchLimit: 1` and "every account writes the live
    /// table" do not compose — the newest row is whoever polled last, which on
    /// an idle login is the *other* account, so an unscoped chip would call
    /// stale data fresh. But a `@Query` predicate is fixed at init, so a scoped
    /// one goes stale the moment the scope changes and reports the previous
    /// account's freshness for as long as the view lives. One row is cheap
    /// enough to just re-read on the two events that can change it.
    @State private var latest: Sample?
    /// Whose reading this is, shown only when there is more than one account.
    ///
    /// Without it the chip is ambiguous exactly when it matters: the pace card
    /// lists two accounts with two different ages — "3 min ago" and "1 min
    /// ago" — and a bare "via oauth · just now" beside them names neither. The
    /// reader cannot tell which number the header is describing, or whether it
    /// is describing a third thing.
    @State private var owner: String?
    @Environment(\.modelContext) private var modelContext

    struct Sample: Equatable {
        let sampledAt: Date
        let source: String
    }

    /// The container is not decoration.
    ///
    /// `content` is `if let latest { … }`, so before the first fetch this
    /// view's body IS an `EmptyView` — and SwiftUI does not run lifecycle
    /// modifiers on an `EmptyView`. Attached directly, `.task` was waiting for
    /// a view that only existed once the task had run: the chip never
    /// appeared, on any scope, from the moment this stopped being a `@Query`
    /// and became `@State` + a keyed fetch. An `HStack` is a real view with a
    /// real (zero-sized) identity, so its modifiers fire.
    ///
    /// Reloads on the rate-limit write signal, read here in `body` so the view
    /// depends on it. It used to reload on scan cycles, which are posted only
    /// when the active login wrote: a chip scoped to the other account, or a
    /// stalled poller (the case the warning is for), never reloaded (#142).
    ///
    /// The age is clock-driven, so the content re-runs every 30 s as well.
    /// Otherwise "3m ago" and the 15-minute warning froze until the next
    /// write, and a stall never turned the chip yellow.
    ///
    /// `latest` and `owner` are read here and handed to the timeline's
    /// content, rather than read inside the closure `TimelineView` stores and
    /// re-runs, so the fetch that fills them redraws this view (#140).
    var body: some View {
        let key = RefreshKey(account: limitAccountId,
                             generation: RateLimitWriteSignal.shared.generation)
        let latest = self.latest, owner = self.owner
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 0) { content(latest: latest, owner: owner) }
        }
        .task(id: key) { refresh() }
    }

    private struct RefreshKey: Equatable {
        let account: String?
        let generation: UInt64
    }

    @MainActor
    private func refresh() {
        latest = (try? modelContext.fetch(
            LimitScope.rateLimits(account: limitAccountId, limit: 1)))?
            .first.map { Sample(sampledAt: $0.sampledAt, source: $0.source) }

        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        owner = accounts.count > 1
            ? accounts.first { $0.id == limitAccountId }?.shortLabel
            : nil
    }

    @ViewBuilder private func content(latest: Sample?, owner: String?) -> some View {
        if let latest {
            // OAuth samples ought to arrive every 5 min; statusline samples
            // are irregular by nature, so the staleness warning is
            // oauth-only. See #3.
            let elapsed = Date().timeIntervalSince(latest.sampledAt)
            let isStaleOAuth = latest.source == RateLimitSource.oauth && elapsed > 15 * 60
            HStack(spacing: 4) {
                if isStaleOAuth {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                }
                Text(owner.map { "\($0) · via \(latest.source) · \(pacerRelative(latest.sampledAt))" }
                     ?? "via \(latest.source) · \(pacerRelative(latest.sampledAt))")
                    .font(.system(size: 11))
            }
            .foregroundStyle(isStaleOAuth ? Color.yellow : .secondary)
            .help(isStaleOAuth
                ? "No fresh data since \(pacerRelative(latest.sampledAt)). \(stallReason())"
                : pacerRelativeExact(latest.sampledAt))
        }
    }

    /// Why the feed stalled, from the poller's own token state rather than a
    /// guess. This always blamed an expired token; more often the usage
    /// endpoint was answering 429 and the poller was backing off (#142).
    private func stallReason() -> String {
        let now = Date()
        let lanes = TokenPoolStatus.shared.lanes.filter {
            limitAccountId == nil || $0.accountKey == limitAccountId
        }
        if let retry = lanes.compactMap(\.cooldownUntil).filter({ $0 > now }).min() {
            return "Polls are backing off after failed requests, usually Anthropic rate-limiting its usage endpoint. Next try \(retry.formatted(date: .omitted, time: .shortened))."
        }
        if lanes.isEmpty {
            return "Pacer has no token for this account."
        }
        if lanes.allSatisfy({ ($0.expiresAt ?? .distantFuture) <= now }) {
            return "The OAuth token has expired. Open or restart Claude Code to refresh it."
        }
        return "Recent polls failed. Details: ~/Library/Logs/Pacer/Pacer.err.log"
    }
}
