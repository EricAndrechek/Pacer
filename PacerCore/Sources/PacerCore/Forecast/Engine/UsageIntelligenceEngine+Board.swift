import Foundation

// The compare sheet's one list (`MeterModelBoard`): every forecaster for a
// meter, the engine's curve fits and the arena's ports alike, ranked the way
// selection ranked them this refit, each with what it can show now. Built
// from what the engine already holds (the ranking, the fit's pick, the live
// cache's failures and the grader's progress); nothing is read from the store
// and no model is run.

extension UsageIntelligenceEngine {

    /// Every model for `windowKey`'s meter (`MeterModelBoard`). Empty rows
    /// before the first refit, and for a window this engine does not fit.
    ///
    /// `weights` is the runtime's lookup, for the off-screen render that has
    /// no runtime (`ArenaRuntime.defaultWeights`, what the app passes it);
    /// with a runtime its own check is used.
    public func meterModelBoard(windowKey key: String,
                                weights: @escaping @Sendable (String) -> URL? = ArenaRuntime.defaultWeights)
        -> MeterModelBoard {
        guard let f = features, let window = f.windows.first(where: { $0.key == key }), let rf = fit.rl[key] else {
            return MeterModelBoard(windowKey: key, rows: [], cutFraction: nil, spanCycles: 0, progress: nil)
        }
        let roster = arena?.roster ?? .standard
        let target = RateLimitRoster.arenaTarget(window: window)
        let specs = target.map { roster.specs(for: $0) } ?? []
        let account = scope.accountId
        let binding = account.flatMap { ArenaWindowBinding.make(account: $0, window: window) }

        let weightsPresent: (ArenaModelSpec) -> Bool
        if let arena {
            weightsPresent = arena.weightsPresent
        } else {
            let services = ArenaServices(weights: weights)
            weightsPresent = { ArenaRecordScorer.weightsPresent($0, roster: roster, services: services) }
        }
        let failure: (String) -> String? = { id in
            guard let binding, let cache = self.arena?.cache else { return nil }
            return cache.failure(.init(account: binding.account, windowKey: binding.windowKey, model: id))
        }
        let progress = account.flatMap { arena?.progress($0) }
        return Self.board(
            windowKey: key, weekly: window.isWeeklyScale, ranking: rlRankings[key],
            current: rlCurrentRankings[key], engineIds: RateLimitRoster.engineIds, specs: specs,
            complexity: Self.rlComplexities(arena: roster), selected: rf.selectedId, shown: rf.resolvedId,
            cutFraction: Self.liveFraction(f, window: window), canRunArena: binding != nil,
            weightsPresent: weightsPresent, liveFailure: failure, progress: progress,
            gradedThrough: account.map { arena?.gradedThrough($0) ?? false } ?? false,
            drawLimit: arena?.compareLimit ?? 4)
    }

    /// What a model with no grade at all says once the grader has been
    /// through the whole depth: it declined every cycle.
    static let boardNoForecastsReason = "no forecasts on your history"
    static let boardThinHistoryReason = "not enough history yet"
    static let boardNeedsAccountReason = "needs an account"

    /// The board from plain values (`meterModelBoard`; tests).
    ///
    /// A row's status, first that holds:
    /// - an arena model this engine cannot run (no account): unavailable;
    /// - its weights (or a child's) not on this Mac: downloading;
    /// - ranked in the grading in use: ranked, or well behind;
    /// - the window has fewer completed cycles than ranking needs:
    ///   unavailable ("not enough history yet");
    /// - nothing graded, while the grader is done with it (or the runtime
    ///   reported why it can't forecast): unavailable, with the reason;
    /// - else scoring: cycles graded of the window's depth, and when the
    ///   grader is on it, when it should be done.
    ///
    /// Order: ranked by typical miss (then complexity, then name), scoring
    /// by how far along, downloading, unavailable, then well behind by miss.
    static func board(
        windowKey: String, weekly: Bool, ranking: EngineSelfEval.RLRanking?, current: EngineSelfEval.RLRanking?,
        engineIds: [String], specs: [ArenaModelSpec], complexity: [String: Int], selected: String?, shown: String?,
        cutFraction: Double?, canRunArena: Bool, weightsPresent: (ArenaModelSpec) -> Bool,
        liveFailure: (String) -> String?, progress: ArenaScoringProgress?, gradedThrough: Bool, drawLimit: Int
    ) -> MeterModelBoard {
        let minPeriods = EngineSelfEval.rlMinPeriods(weekly: weekly)
        let current = current ?? ranking
        let depth = progress?.windowDepth[windowKey]
            ?? max(current?.depthCycles ?? 0, ranking?.depthCycles ?? 0)
        let scoring = Set(progress?.models ?? [])
        let drawn = Set(drawnIds(pick: selected, ranking: ranking, limit: drawLimit) + (shown.map { [$0] } ?? []))
        let pick = shown ?? selected
        let specByName = Dictionary(specs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var ids: [String] = []
        var seen = Set<String>()
        for id in engineIds + specs.map(\.name) where seen.insert(id).inserted { ids.append(id) }

        let rows = ids.map { id -> MeterModelBoard.Row in
            let spec = specByName[id]
            let status: MeterModelBoard.Status
            if spec != nil, !canRunArena {
                status = .unavailable(boardNeedsAccountReason)
            } else if let spec, !weightsPresent(spec) {
                status = .downloading(fraction: nil)
            } else if let st = ranking?.standing(id), let miss = st.typicalAbsError {
                status = st.wellBehind ? .wellBehind(typicalMiss: miss, cycles: st.spanCycles)
                                       : .ranked(typicalMiss: miss, cycles: st.spanCycles)
            } else {
                let done = current?.standing(id)?.cycles ?? 0
                if depth < minPeriods && done >= depth {
                    status = .unavailable(boardThinHistoryReason)
                } else if spec != nil, done == 0, !scoring.contains(id),
                          let reason = liveFailure(id), reason != "downloading" {
                    status = .unavailable(reason)
                } else if spec != nil, done == 0, gradedThrough {
                    status = .unavailable(boardNoForecastsReason)
                } else {
                    status = .scoring(done: done, total: max(depth, done),
                                      eta: scoring.contains(id) ? progress?.eta : nil)
                }
            }
            return MeterModelBoard.Row(
                id: id, name: BurnTrajectory.displayName(id), summary: BurnTrajectory.summary(id), status: status,
                isPick: id == pick, drawnByDefault: drawn.contains(id), complexity: complexity[id] ?? spec?.complexity ?? 3)
        }

        func key(_ r: MeterModelBoard.Row) -> (group: Int, value: Double) {
            switch r.status {
            case .ranked(let miss, _): return (0, miss)
            case .scoring(let done, _, _): return (1, -Double(done))
            case .downloading: return (2, 0)
            case .unavailable: return (3, 0)
            case .wellBehind(let miss, _): return (4, miss)
            }
        }
        let sorted = rows.sorted { a, b in
            let ka = key(a), kb = key(b)
            if ka.group != kb.group { return ka.group < kb.group }
            if ka.value != kb.value { return ka.value < kb.value }
            if a.complexity != b.complexity { return a.complexity < b.complexity }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
        return MeterModelBoard(
            windowKey: windowKey, rows: sorted, cutFraction: cutFraction, spanCycles: ranking?.span?.cycles ?? 0,
            progress: progress.map { .init(done: $0.cyclesDone, total: $0.cyclesTotal, eta: $0.eta) })
    }
}
