import Foundation
import SwiftData

/// One `UsageIntelligenceEngine` per scope, created on demand.
///
/// The engine fits a single series, so "what will this account spend by
/// tonight" and "what will every account spend by tonight" are two different
/// fits — not one fit filtered. This owns them.
///
/// **Only scopes something is looking at get fitted.** `.allAccounts` is
/// always live because the menu bar, alerts, widgets and the HTTP API read it
/// whatever the window is showing. A per-account engine is created the first
/// time a view asks for one and then kept warm, so switching back and forth
/// costs nothing. A refit is ~1.1 s of background work per scope per
/// five-minute cycle; two scopes is well under 1% duty, and the engines are
/// separate actors so their refits overlap rather than queue.
@MainActor
public final class EngineHost {
    private let container: ModelContainer
    private var engines: [EngineScope: UsageIntelligenceEngine] = [:]

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

    /// The engine for a view's scope. `nil` account means every account.
    public func engine(forAccount accountId: String?) -> UsageIntelligenceEngine {
        engine(for: accountId.map(EngineScope.account) ?? .allAccounts)
    }

    public var scopes: [EngineScope] { Array(engines.keys) }

    /// Every live scope's engine, for the recompute tick.
    public var all: [(scope: EngineScope, engine: UsageIntelligenceEngine)] {
        engines.map { ($0.key, $0.value) }
    }
}
