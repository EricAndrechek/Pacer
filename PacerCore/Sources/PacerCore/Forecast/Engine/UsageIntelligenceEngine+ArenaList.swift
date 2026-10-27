import Foundation

// Every arena model a window can run, with where each stands on this user's
// record: what the compare sheet lists under the models it draws.
//
// The sheet draws the engine's methods, the pick and the few best-recorded
// arena models (`arenaRoster`, `ArenaEngineLink.compareLimit`): each drawn
// arena model is a live projection per refit, so that set stays small. Until
// a model has `EngineSelfEval.arenaMinPeriods` cycles behind it, it is in
// none of them, and a fresh install showed none of the ported models at all
// while the background scorer was filling their record. This lists them all,
// drawn or not, from what the engine already holds: the accuracy the refit
// computed, the fit's pick and live roster, and the live cache's failures.
// Nothing is read from the store.

/// One arena model's standing on one window, for the compare sheet.
public struct ArenaModelListing: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        /// At least the selection floor of cycles scored: `typicalAbsError`
        /// is the number the drawn rows show.
        case recorded
        /// Its weights are here and the scorer is filling its record:
        /// `cycles` of the `floor` it needs to be picked.
        case scoring(cycles: Int, floor: Int)
        /// Its pretrained weights, or a child's, are not on this Mac yet.
        case downloading
        /// The runtime could not forecast it, and why, in the sheet's terms.
        case declined(String)
    }

    public let id: String
    public let name: String
    /// Completed cycles of this window it has been scored on, its whole
    /// record: what counts towards the selection floor.
    public let cycles: Int
    /// The record's typical miss (`EngineSelfEval.Accuracy.MethodStat`), only
    /// once `cycles` reaches the selection floor; nil before. Measured over
    /// the sheet's span (`EngineSelfEval.comparableAccuracy`), the cycles the
    /// drawn rows' numbers cover, so the two halves of the list compare.
    public let typicalAbsError: Double?
    /// The record's pick for this window.
    public let isPick: Bool
    /// Whether it has a live line this cycle.
    public let isDrawn: Bool
    public let status: Status

    public init(id: String, name: String, cycles: Int, typicalAbsError: Double?, isPick: Bool, isDrawn: Bool,
                status: Status) {
        self.id = id; self.name = name; self.cycles = cycles; self.typicalAbsError = typicalAbsError
        self.isPick = isPick; self.isDrawn = isDrawn; self.status = status
    }
}

extension UsageIntelligenceEngine {

    /// Every selectable arena model that forecasts `windowKey`'s meter, best
    /// record first (`arenaListing`). Empty for a window no arena target
    /// covers, before the first refit, and for an engine with no account (the
    /// arena runs per account).
    ///
    /// Without the runtime (the off-screen render) the app's standard roster
    /// is listed from the same record, so the sheet it draws is the app's,
    /// without live lines. `weights` is the runtime's lookup
    /// (`ArenaRuntime.defaultWeights`, what the app passes it); tests pass
    /// their own. `live` is the value the trajectories were asked with, so
    /// `isDrawn` agrees with the sheet's lines.
    public func arenaModelList(windowKey key: String, live: LiveMeterValue? = nil,
                               weights: @escaping @Sendable (String) -> URL? = ArenaRuntime.defaultWeights)
        -> [ArenaModelListing] {
        guard let f = features, let account = scope.accountId,
              let window = f.windows.first(where: { $0.key == key }),
              let binding = ArenaWindowBinding.make(account: account, window: window) else { return [] }
        let roster = arena?.roster ?? .standard
        let specs = roster.specs(for: binding.target)
        guard !specs.isEmpty else { return [] }

        // The live roster (`arenaRoster`): only these are asked for a
        // projection, so only these can have a line or a failure this cycle.
        let liveIds = Set(arenaModelIds(windowKey: key))
        var drawn = Set<String>()
        var failures: [String: String] = [:]
        if let cache = arena?.cache, !liveIds.isEmpty {
            func cacheKey(_ id: String) -> ArenaLiveCache.Key {
                .init(account: binding.account, windowKey: binding.windowKey, model: id)
            }
            // The cycle `ArenaCachedBurnModel.fit` is handed, live value and all.
            if let samples = f.rateLimit[key],
               let cycle = BurnTrajectory.segment(samples: samples, duration: window.duration, now: f.now)
                   .current?.withLive(live, duration: window.duration) {
                drawn = liveIds.filter { cache.projection(cacheKey($0), cycle: cycle) != nil }
            }
            for id in liveIds where !drawn.contains(id) {
                if let reason = cache.failure(cacheKey(id)) { failures[id] = reason }
            }
        }

        // A weight id is looked up once, however many models share it.
        let runner = ArenaRunner(registry: roster.registry)
        var present: [String: Bool] = [:]
        let weightsPresent = { (spec: ArenaModelSpec) -> Bool in
            runner.requiredWeights(spec.name).allSatisfy { id in
                if let known = present[id] { return known }
                let here = weights(id) != nil
                present[id] = here
                return here
            }
        }

        return Self.arenaListing(
            specs: specs, accuracy: selfEvalAccuracy(surface: EngineSelfEval.rlSurface(key)),
            weekly: window.isWeeklyScale, pick: resolvedMethod(windowKey: key).selected, drawn: drawn,
            liveFailure: { failures[$0] }, weightsPresent: weightsPresent)
    }

    /// What a window's arena models have no number for yet: a model with no
    /// record while others have their floor declined every cycle the scorer
    /// gave it (it scores every model at each cut of a cycle together).
    static let arenaNoForecastsReason = "no forecasts on your history"

    /// The listing, from plain values (`arenaModelList`; tests).
    ///
    /// Status, first that holds: a record at the selection floor; weights not
    /// here; a live failure the runtime reported this cycle (its own words,
    /// "downloading" excepted: the weights check above is current, the
    /// failure may predate their arrival); no cycles while another model with
    /// its weights has its floor (it declined them); else still scoring.
    ///
    /// Order: recorded models by typical miss, best first (the drawn rows'
    /// statistic), then the rest by how far their record has come, then
    /// declined, then downloading. Ties by name, then id, so the list holds
    /// still between refits.
    static func arenaListing(
        specs: [ArenaModelSpec], accuracy: EngineSelfEval.Accuracy?, weekly: Bool, pick: String?,
        drawn: Set<String>, liveFailure: (String) -> String?, weightsPresent: (ArenaModelSpec) -> Bool
    ) -> [ArenaModelListing] {
        let floor = EngineSelfEval.arenaMinPeriods(weekly: weekly)
        var stats: [String: EngineSelfEval.Accuracy.MethodStat] = [:]
        for m in accuracy?.methods ?? [] { stats[m.method] = m }
        let ready = Dictionary(specs.map { ($0.name, weightsPresent($0)) }, uniquingKeysWith: { a, _ in a })
        // The deepest record among models that could run: how far the scorer
        // has got on this window.
        let deepest = specs.filter { ready[$0.name] == true }.map { stats[$0.name]?.periods ?? 0 }.max() ?? 0

        var seen = Set<String>()
        let listed = specs.compactMap { spec -> ArenaModelListing? in
            guard seen.insert(spec.name).inserted else { return nil }
            let cycles = stats[spec.name]?.periods ?? 0
            let recorded = cycles >= floor
            let error = recorded ? stats[spec.name].map(\.typicalAbsError).flatMap { $0.isFinite ? $0 : nil } : nil
            let status: ArenaModelListing.Status
            if recorded {
                status = .recorded
            } else if ready[spec.name] != true {
                status = .downloading
            } else if let reason = liveFailure(spec.name), reason != "downloading" {
                status = .declined(reason)
            } else if cycles == 0 && deepest >= floor {
                status = .declined(arenaNoForecastsReason)
            } else {
                status = .scoring(cycles: cycles, floor: floor)
            }
            return ArenaModelListing(
                id: spec.name, name: ArenaModelNames.displayName(spec.name) ?? spec.name, cycles: cycles,
                typicalAbsError: error, isPick: spec.name == pick, isDrawn: drawn.contains(spec.name),
                status: status)
        }
        return listed.sorted { a, b in
            let ka = sortKey(a), kb = sortKey(b)
            if ka.rank != kb.rank { return ka.rank < kb.rank }
            if ka.value != kb.value { return ka.value < kb.value }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
    }

    private static func sortKey(_ l: ArenaModelListing) -> (rank: Int, value: Double) {
        switch l.status {
        case .recorded: return l.typicalAbsError.map { (0, $0) } ?? (1, 0)
        case .scoring(let cycles, _): return (2, -Double(cycles))
        case .declined: return (3, 0)
        case .downloading: return (4, 0)
        }
    }
}
