import Foundation
import SwiftData

/// One `UsageIntelligenceEngine` per scope, created on demand.
///
/// The engine fits a single series, so "what will this account spend by
/// tonight" and "what will every account spend by tonight" are two different
/// fits — not one fit filtered. This owns them.
///
/// **Every account's forecast is kept current**, plus `.allAccounts`, whatever
/// the window is showing: `AppBackgroundService` hands the account list to
/// `keepFitted(accounts:)` before each refit. Until 2026-09-25 only scopes a
/// view or the API had asked for in the last fifteen minutes were refitted, so
/// an account nobody was looking at had a forecast frozen at the last time
/// someone did. That was a cost decision (see below). The per-scope refit got
/// much cheaper when the scoreboard stopped being re-read every refit (#155),
/// and a forecast should not depend on what happens to be on screen.
///
/// **What a refit actually costs.** This used to say "~1.1 s per scope per
/// five-minute cycle; two scopes is well under 1% duty". Measured on a
/// two-account store it was 97 refits in a day at a median of 15.9 s, worst
/// 41 s — half an hour of work, and 83% of the pace card's multi-second loads
/// landed inside one. The estimate was out by more than ten times, in the
/// direction that matters.
///
/// The lever that works is fitting fewer scopes: `live` rather than `all`.
/// Serialising the refits was tried and rejected — one engine fits in ~13.2 s
/// and three concurrent in ~15.9 s, so they overlap almost perfectly and going
/// serial would stretch the window the rest of the app waits on from ~16 s to
/// ~40 s for identical work. `AppBackgroundService` carries that measurement
/// next to the code that keeps the task group.
@MainActor
public final class EngineHost {
    private let container: ModelContainer
    private var engines: [EngineScope: UsageIntelligenceEngine] = [:]
    /// When each scope was last asked for. Keeps a scope outside
    /// `keptAccounts` live for a while after its last ask — see `live`.
    private var lastAsked: [EngineScope: Date] = [:]
    /// Every account Pacer knows about, refitted every cycle. See
    /// `keepFitted(accounts:)`.
    private var keptAccounts: Set<String> = []

    /// How long a scope outside `keptAccounts` keeps being refitted after the
    /// last view asked for it. Every known account is refitted anyway, so this
    /// only matters for an account the store doesn't list yet.
    ///
    /// Generous on purpose: flicking between accounts must not pay a cold fit
    /// each time, and a fit that is one cycle stale is still a fit. What this
    /// stops is the *permanent* cost — before it, asking for a scope once kept
    /// it refitting for the life of the process.
    public static let idleScopeGrace: TimeInterval = 15 * 60

    public init(container: ModelContainer) {
        self.container = container
        _ = engine(for: .allAccounts)
    }

    /// Build a host around engines that already exist and are already fitted.
    ///
    /// For headless rendering. The normal init warms `.allAccounts` on a
    /// detached task, which is right in the app and a race against a capture
    /// that happens at a fixed settle: the screenshot scenes fit their engine
    /// synchronously against a synthetic fixture and then have nothing to wait
    /// for. Without this they got no host at all — the environment carried only
    /// the older single-engine key, so every view that moved to a per-scope
    /// engine silently rendered no forecast at all, and the README's headline
    /// screenshot lost its projections, its at-reset chips and its
    /// pace-vs-normal chip.
    public init(container: ModelContainer, preseeded: [EngineScope: UsageIntelligenceEngine]) {
        self.container = container
        self.engines = preseeded
        if engines[.allAccounts] == nil { _ = engine(for: .allAccounts) }
    }

    /// The all-accounts engine — what anything that must not follow the
    /// window's scope reads: alerts, the menu bar's gauges, the HTTP API.
    public var global: UsageIntelligenceEngine { engine(for: .allAccounts) }

    /// The engine for a scope, creating and warming it on first ask.
    ///
    /// A newly created engine has no fit yet, so it answers `.insufficient`
    /// until its first recompute lands. That is why the first one is kicked off
    /// here rather than waiting for the next scan tick — a scope switch should
    /// fill in within a second, not within five minutes.
    @discardableResult
    public func engine(for scope: EngineScope) -> UsageIntelligenceEngine {
        lastAsked[scope] = Date()
        if let existing = engines[scope] { return existing }
        let engine = UsageIntelligenceEngine(modelContainer: container)
        engines[scope] = engine
        // `Task.detached`, emphatically. This type is `@MainActor`, and a plain
        // `Task` inherits that — so `await engine.recompute()` resumes the fit
        // *inline on the main thread* under the uncontended-actor optimisation.
        // Measured: a 10.2 second main-thread stall the first time a scope was
        // asked for. `AppBackgroundService` carries the same warning on its own
        // recompute; I walked straight into it anyway.
        Task.detached(priority: .userInitiated) {
            await engine.adopt(scope: scope)
            await engine.recompute()
            await MainActor.run {
                NotificationCenter.default.post(name: .pacerEngineDidRecompute, object: nil)
            }
        }
        return engine
    }

    /// Keep every one of these accounts' forecasts current, asked for or not.
    ///
    /// Called before each refit with the store's account list. An account
    /// without an engine gets one here, *without* the warm-up fit
    /// `engine(for:)` starts: the refit this call precedes fits it anyway, and
    /// a second fit racing the first would do the work twice.
    ///
    /// Awaits each new engine's `adopt(scope:)` before returning. A recompute
    /// reaching an engine before its scope is set would fit every account's
    /// data under one account's name. Adopting only sets the scope, so the hop
    /// costs nothing.
    public func keepFitted(accounts ids: [String]) async {
        keptAccounts = Set(ids)
        for id in ids where engines[.account(id)] == nil {
            let scope = EngineScope.account(id)
            let engine = UsageIntelligenceEngine(modelContainer: container)
            engines[scope] = engine
            await engine.adopt(scope: scope)
        }
    }

    /// The engine for a view's scope. `nil` account means every account.
    public func engine(forAccount accountId: String?) -> UsageIntelligenceEngine {
        engine(for: accountId.map(EngineScope.account) ?? .allAccounts)
    }

    public var scopes: [EngineScope] { Array(engines.keys) }

    /// Test seam: backdate a scope's last-asked stamp so the grace period can
    /// be exercised without waiting fifteen minutes.
    public func markAskedForTesting(_ scope: EngineScope, at date: Date) {
        lastAsked[scope] = date
    }

    /// Every scope's engine, whether or not anything is still reading it.
    public var all: [(scope: EngineScope, engine: UsageIntelligenceEngine)] {
        engines.map { ($0.key, $0.value) }
    }

    /// The scopes worth refitting: `.allAccounts`, every account passed to
    /// `keepFitted(accounts:)`, and any other scope something has asked for
    /// recently.
    ///
    /// **This is the expensive list, and it used to be `all`.** Measured on a
    /// two-account store: 97 refits in a day, median 15.9 s, worst 41 s, half
    /// an hour of work in total — against a doc comment on this type claiming
    /// "~1.1 s per scope" and "well under 1% duty". Three engines were being
    /// fitted every cycle because asking for a scope once kept it alive for the
    /// life of the process, so scoping the dashboard to an account in the
    /// morning bought a permanent third of that cost.
    ///
    /// `.allAccounts` is never dropped: alerts, the menu bar, the widgets and
    /// the HTTP API all read it regardless of what the window is showing.
    public var live: [(scope: EngineScope, engine: UsageIntelligenceEngine)] {
        let cutoff = Date().addingTimeInterval(-Self.idleScopeGrace)
        return engines.compactMap { scope, engine in
            guard scope != .allAccounts else { return (scope, engine) }
            if let id = scope.accountId, keptAccounts.contains(id) { return (scope, engine) }
            guard let asked = lastAsked[scope], asked >= cutoff else { return nil }
            return (scope, engine)
        }
    }
}
