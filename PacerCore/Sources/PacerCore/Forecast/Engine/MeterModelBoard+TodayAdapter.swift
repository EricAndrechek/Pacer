import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// TEMPORARY: DELETE THIS FILE ON MERGE with `feat/fm-unified-eval`, which
// builds the real `UsageIntelligenceEngine.meterModelBoard(windowKey:)`.
// Delete `MeterModelBoardAdapterTests.swift` with it.
//
// Until then the compare sheet reads its board from here: what the engine
// already holds (the span accuracy, the arena listing, the fit's pick, the
// scorer's progress) mapped into a `MeterModelBoard`. The method has the real
// one's name and shape on purpose, so deleting this file leaves the sheet
// calling the real one with no edit. Where this guesses at something the
// real board decides (which rows are well behind, the ETA), the real board
// wins.
// ─────────────────────────────────────────────────────────────────────────────

extension UsageIntelligenceEngine {

    /// Every forecaster for `windowKey`'s meter, from today's data.
    public func meterModelBoard(windowKey key: String) -> MeterModelBoard {
        let roster = arena?.roster ?? .standard
        var cut: Double?
        if let f = features, let window = f.windows.first(where: { $0.key == key }), let samples = f.rateLimit[key],
           let current = BurnTrajectory.segment(samples: samples, duration: window.duration, now: f.now).current,
           current.resetsAt > f.now, window.duration > 0 {
            cut = min(1, max(0, f.now.timeIntervalSince(current.cycleStart) / window.duration))
        }
        return MeterModelBoardAdapter.board(
            windowKey: key, engineIds: RateLimitRoster.engineIds, listings: arenaModelList(windowKey: key),
            accuracy: selfEvalAccuracy(surface: EngineSelfEval.rlSurface(key)),
            pick: resolvedMethod(windowKey: key).resolved,
            complexities: RateLimitRoster.complexities(arena: roster), cutFraction: cut,
            progress: scope.accountId.flatMap { ArenaScoringProgressBoard.shared.progress(account: $0) })
    }
}

/// The mapping, from plain values (`meterModelBoard`; tests).
enum MeterModelBoardAdapter {

    /// Drawn when the sheet opens besides the pick: the next this many ranked.
    static let defaultDrawnBesidesPick = 4

    /// What an engine method with no record says.
    static let noHistory = "not enough history yet"

    static func board(
        windowKey: String, engineIds: [String], listings: [ArenaModelListing], accuracy: EngineSelfEval.Accuracy?,
        pick: String?, complexities: [String: Int], cutFraction: Double?, progress: ArenaScoringProgress?
    ) -> MeterModelBoard {
        // Every ranked number covers the span; without one, the deepest record.
        let span = accuracy?.span?.cycles ?? (accuracy?.methods.map(\.shownPeriods).max() ?? 0)
        let cyclesBehind = { (id: String) in accuracy?.partialCycles(id) ?? span }

        var rows: [MeterModelBoard.Row] = []
        var seen = Set<String>()
        func add(_ id: String, _ status: MeterModelBoard.Status) {
            guard seen.insert(id).inserted else { return }
            rows.append(.init(id: id, name: BurnTrajectory.displayName(id), summary: BurnTrajectory.summary(id),
                              status: status, isPick: id == pick, drawnByDefault: false,
                              complexity: complexities[id] ?? 3))
        }
        for id in engineIds {
            if let s = accuracy?.stat(id), s.typicalAbsError.isFinite, s.shownPeriods > 0 {
                add(id, .ranked(typicalMiss: s.typicalAbsError, cycles: cyclesBehind(id)))
            } else {
                add(id, .unavailable(noHistory))
            }
        }
        for l in listings {
            switch l.status {
            case .recorded:
                if let miss = l.typicalAbsError { add(l.id, .ranked(typicalMiss: miss, cycles: cyclesBehind(l.id))) }
                else { add(l.id, .unavailable(noHistory)) }
            case let .scoring(cycles, floor): add(l.id, .scoring(done: cycles, total: floor, eta: nil))
            case .downloading: add(l.id, .downloading(fraction: nil))
            case let .declined(reason): add(l.id, .unavailable(reason))
            }
        }

        // Well behind: the rule the scorer prunes arena models by
        // (`EngineSelfEval.arenaLosersToEngine`: half again the best's error
        // plus a point), applied to every ranked row against the best one.
        // The real board decides this from the record; never the pick.
        let best = rows.compactMap { r -> Double? in
            if case let .ranked(m, _) = r.status { return m }
            return nil
        }.min()
        if let best {
            let limit = best * EngineSelfEval.arenaLossRatio + EngineSelfEval.arenaLossMargin
            for i in rows.indices where !rows[i].isPick {
                if case let .ranked(m, c) = rows[i].status, m > limit { rows[i].status = .wellBehind(typicalMiss: m, cycles: c) }
            }
        }

        rows.sort { a, b in
            let ka = sortKey(a.status), kb = sortKey(b.status)
            if ka.rank != kb.rank { return ka.rank < kb.rank }
            if ka.value != kb.value { return ka.value < kb.value }
            if a.complexity != b.complexity { return a.complexity < b.complexity }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }

        // The pick and the next few ranked.
        var others = 0
        for i in rows.indices {
            if rows[i].isPick { rows[i].drawnByDefault = true; continue }
            if case .ranked = rows[i].status, others < defaultDrawnBesidesPick {
                rows[i].drawnByDefault = true
                others += 1
            }
        }

        let p = progress.flatMap { p -> MeterModelBoard.Progress? in
            p.cyclesTotal > 0 ? .init(done: p.cyclesDone, total: p.cyclesTotal, eta: nil) : nil
        }
        return MeterModelBoard(windowKey: windowKey, rows: rows, cutFraction: cutFraction, spanCycles: span, progress: p)
    }

    private static func sortKey(_ s: MeterModelBoard.Status) -> (rank: Int, value: Double) {
        switch s {
        case let .ranked(m, _): return (0, m)
        case let .scoring(done, total, _): return (1, total > 0 ? -Double(done) / Double(total) : 0)
        case .downloading: return (2, 0)
        case .unavailable: return (3, 0)
        case let .wellBehind(m, _): return (4, m)
        }
    }
}
