import Foundation

/// Forward-trajectory forecasting for a rate-limit window's usage curve — the
/// model layer behind the dashed projection overlaid on the 5h/7d pace charts.
///
/// Unlike the end-of-period *total* ensemble (which returns a scalar), a burn
/// surface wants the whole forward *curve*: usage% at every future instant
/// from now to the window reset, so it can be drawn against the actual line.
/// Same tournament idea though — several curve fits compete, scored by how
/// well they predicted the *remainder* of the user's past cycles, and the
/// per-window winner's trajectory is what we plot.
///
/// On real data there's no universal winner (recency-weighted tracks the 5h
/// window best; plain linear-over-a-recent-window tracks the 7d best), which
/// is exactly why this is a backtest-selected ensemble rather than one
/// hardcoded fit.
public enum BurnTrajectory {

    /// One usage observation in a cycle.
    public struct Sample: Sendable, Equatable {
        public let at: Date
        public let usedPercentage: Double
        public init(at: Date, usedPercentage: Double) {
            self.at = at
            self.usedPercentage = usedPercentage
        }
    }

    /// A cycle's samples plus its boundaries. `now` is the projection origin
    /// (the latest real sample for the live chart; a past cut for backtests).
    public struct PartialCycle: Sendable {
        public let samples: [Sample]      // within [cycleStart, now], time-ordered
        public let now: Date
        public let cycleStart: Date
        public let resetsAt: Date
        public init(samples: [Sample], now: Date, cycleStart: Date, resetsAt: Date) {
            self.samples = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
            self.now = now
            self.cycleStart = cycleStart
            self.resetsAt = resetsAt
        }
        public var durationHours: Double { resetsAt.timeIntervalSince(cycleStart) / 3600 }
        public var nowHours: Double { now.timeIntervalSince(cycleStart) / 3600 }
        func hours(_ date: Date) -> Double { date.timeIntervalSince(cycleStart) / 3600 }
        public var usedNow: Double { samples.last?.usedPercentage ?? 0 }
    }

    /// A complete past cycle, used for backtesting.
    public struct Cycle: Sendable {
        public let samples: [Sample]
        public let cycleStart: Date
        public let resetsAt: Date
        public init(samples: [Sample], cycleStart: Date, resetsAt: Date) {
            self.samples = samples.sorted { $0.at < $1.at }
            self.cycleStart = cycleStart
            self.resetsAt = resetsAt
        }
    }

    /// A curve-fit candidate. `fit` returns a closure giving projected usage%
    /// at any future date, or nil when it can't fit the cycle-so-far.
    public protocol Model: Sendable {
        var id: String { get }
        var complexity: Int { get }
        func fit(_ cycle: PartialCycle) -> (@Sendable (Date) -> Double)?
    }

    /// The selected fit's forward trajectory, sampled for plotting.
    public struct Trajectory: Sendable, Equatable {
        public let modelId: String
        /// Points from `now` to `resetsAt`, inclusive, clamped to 0…100 for display.
        public let points: [Sample]
        /// First future instant the (unclamped) projection reaches 100%, if any.
        public let crossesFullAt: Date?
    }

    /// Default roster. Quadratic is deliberately excluded — it reliably
    /// explodes on real cycles and was the worst fit in every backtest.
    public static var defaultModels: [any Model] {
        [
            LinearRecent(),
            RecencyWeighted(),
            DampedAcceleration(),
            Saturating(),
        ]
    }

    // MARK: - Backtest + selection

    /// Score each model by how well it predicted the *remainder* of past
    /// cycles, reusing the ensemble's `Backtester.Score` so the shared
    /// `ForecastSelector` can pick the winner. Error is median absolute
    /// percentage-*points* over the unseen tail of each cycle.
    public static func score(
        models: [any Model],
        cycles: [Cycle],
        cutFractions: [Double] = [0.5, 0.6, 0.7]
    ) -> [Backtester.Score] {
        models.map { model in
            var errors: [Double] = []
            var attempts = 0
            for cycle in cycles {
                let duration = cycle.resetsAt.timeIntervalSince(cycle.cycleStart)
                for cf in cutFractions {
                    let now = cycle.cycleStart.addingTimeInterval(duration * cf)
                    let seen = cycle.samples.filter { $0.at <= now }
                    let future = cycle.samples.filter { $0.at > now }
                    guard seen.count >= 3, future.count >= 2 else { continue }
                    attempts += 1
                    let partial = PartialCycle(samples: seen, now: now,
                                               cycleStart: cycle.cycleStart, resetsAt: cycle.resetsAt)
                    guard let projection = model.fit(partial) else { continue }
                    let absErrors = future.map { abs(projection($0.at) - $0.usedPercentage) }
                    errors.append(absErrors.sorted()[absErrors.count / 2])  // per-cycle median
                }
            }
            let coverage = attempts == 0 ? 0 : Double(errors.count) / Double(attempts)
            return Backtester.Score(
                id: model.id, complexity: model.complexity,
                medianAbsPctError: median(errors),
                meanAbsPctError: errors.isEmpty ? .infinity : errors.reduce(0, +) / Double(errors.count),
                coverage: coverage, scoredCount: errors.count)
        }
    }

    /// Backtest-select the best model for `history`, fit it to the current
    /// cycle, and return its forward trajectory sampled `sampleCount` times
    /// from now to reset. Falls back to the first model that can fit when the
    /// backtest is inconclusive (too little history). `nil` if nothing fits.
    public static func bestTrajectory(
        current: PartialCycle,
        history: [Cycle],
        models: [any Model] = defaultModels,
        priorScores: [Backtester.Score]? = nil,
        selectionPolicy: ForecastSelector.Policy = .init(minScoredCases: 6, minCoverage: 0.5),
        sampleCount: Int = 48
    ) -> Trajectory? {
        let pickId = selectModel(history: history, models: models,
                                 priorScores: priorScores, policy: selectionPolicy)
        let chosen = models.first { $0.id == pickId }
            ?? models.first { $0.fit(current) != nil }
        guard let model = chosen, let projection = model.fit(current) else { return nil }

        let span = current.resetsAt.timeIntervalSince(current.now)
        guard span > 0 else { return nil }
        var points: [Sample] = []
        var crossing: Date?
        for i in 0...sampleCount {
            let date = current.now.addingTimeInterval(span * Double(i) / Double(sampleCount))
            let raw = projection(date)
            if crossing == nil, raw >= 100 { crossing = date }
            points.append(Sample(at: date, usedPercentage: min(100, max(0, raw))))
        }
        return Trajectory(modelId: model.id, points: points, crossesFullAt: crossing)
    }

    /// Segment a flat run of samples (each carrying its window's `resetsAt`)
    /// into the current partial cycle and the prior complete cycles, by
    /// grouping on the reset boundary. The group whose reset is latest is the
    /// current cycle; the rest are history for the backtest. `duration` is the
    /// window length (5h or 7d). Order-agnostic.
    public static func segment(
        samples: [(at: Date, usedPercentage: Double, resetsAt: Date)],
        duration: TimeInterval,
        now: Date
    ) -> (current: PartialCycle?, history: [Cycle]) {
        let sorted = samples.sorted { $0.at < $1.at }
        var groups: [Date: [(at: Date, usedPercentage: Double, resetsAt: Date)]] = [:]
        // Bucket by reset rounded to the minute so jitter doesn't split a cycle.
        for s in sorted {
            let key = Date(timeIntervalSince1970: (s.resetsAt.timeIntervalSince1970 / 60).rounded() * 60)
            groups[key, default: []].append(s)
        }
        guard let currentReset = groups.keys.max() else { return (nil, []) }

        var history: [Cycle] = []
        var current: PartialCycle?
        for (key, rows) in groups {
            // Use the real reset from the readings, not the rounded group key.
            let reset = rows.map { $0.resetsAt }.max() ?? key
            let cycleStart = reset.addingTimeInterval(-duration)
            let samples = rows.map { Sample(at: $0.at, usedPercentage: $0.usedPercentage) }
            if key == currentReset {
                current = PartialCycle(samples: samples, now: now, cycleStart: cycleStart, resetsAt: reset)
            } else {
                history.append(Cycle(samples: samples, cycleStart: cycleStart, resetsAt: reset))
            }
        }
        return (current, history.sorted { $0.cycleStart < $1.cycleStart })
    }

    /// Choose the model id: prefer the persisted scoreboard (`priorScores`)
    /// when it yields an eligible pick — that's the self-improving feedback
    /// loop — otherwise fall back to the cold-start on-the-fly backtest over
    /// `history`.
    static func selectModel(
        history: [Cycle],
        models: [any Model],
        priorScores: [Backtester.Score]?,
        policy: ForecastSelector.Policy
    ) -> String? {
        if let priorScores, let learned = ForecastSelector.select(scores: priorScores, policy: policy).id {
            return learned
        }
        return ForecastSelector.select(scores: score(models: models, cycles: history), policy: policy).id
    }

    /// One model's forward trajectory plus its backtest accuracy — for the
    /// "show all models" detail view.
    public struct ScoredTrajectory: Sendable, Identifiable {
        public let modelId: String
        public let complexity: Int
        public let trajectory: Trajectory
        /// Median absolute error (percentage points) over the remainder of
        /// past cycles. `.infinity` when there wasn't enough history to score.
        public let medianAbsError: Double
        public let coverage: Double
        public let isSelected: Bool
        public var id: String { modelId }
    }

    /// Fit *every* model to the current cycle and pair each trajectory with
    /// its backtest accuracy, flagging the one the selector would pick. Powers
    /// the detail view that plots all candidates side by side.
    public static func allTrajectories(
        current: PartialCycle,
        history: [Cycle],
        models: [any Model] = defaultModels,
        priorScores: [Backtester.Score]? = nil,
        selectionPolicy: ForecastSelector.Policy = .init(minScoredCases: 6, minCoverage: 0.5),
        sampleCount: Int = 48
    ) -> [ScoredTrajectory] {
        let scores = score(models: models, cycles: history)
        let selectedId = selectModel(history: history, models: models,
                                     priorScores: priorScores, policy: selectionPolicy)
        let span = current.resetsAt.timeIntervalSince(current.now)
        guard span > 0 else { return [] }

        return models.compactMap { model -> ScoredTrajectory? in
            guard let projection = model.fit(current) else { return nil }
            var points: [Sample] = []
            var crossing: Date?
            for i in 0...sampleCount {
                let date = current.now.addingTimeInterval(span * Double(i) / Double(sampleCount))
                let raw = projection(date)
                if crossing == nil, raw >= 100 { crossing = date }
                points.append(Sample(at: date, usedPercentage: min(100, max(0, raw))))
            }
            let s = scores.first { $0.id == model.id }
            return ScoredTrajectory(
                modelId: model.id, complexity: model.complexity,
                trajectory: Trajectory(modelId: model.id, points: points, crossesFullAt: crossing),
                medianAbsError: s?.medianAbsPctError ?? .infinity,
                coverage: s?.coverage ?? 0,
                isSelected: model.id == selectedId)
        }
    }

    // MARK: - Completed-cycle scoring (the feedback loop)

    /// A model's verdict over one completed cycle: overall accuracy and how
    /// early it converged.
    public struct CycleScore: Sendable, Equatable {
        public let modelId: String
        public let meanAbsError: Double
        public let convergenceFraction: Double
    }

    /// Within this many percentage points of the realized final counts as
    /// "locked in" for the convergence metric.
    public static let convergenceTolerance: Double = 5

    /// Score each model over a *completed* cycle: replay it at a grid of cut
    /// points, projecting the final each time, and measure (a) mean absolute
    /// error vs the realized final and (b) the earliest cut fraction from
    /// which it stayed within `tolerance`. This is what gets persisted as
    /// `ForecastModelOutcome` and aggregated by `ForecastScoreboard`.
    public static func scoreCompletedCycle(
        _ cycle: Cycle,
        models: [any Model] = defaultModels,
        cutFractions: [Double] = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9],
        tolerance: Double = convergenceTolerance
    ) -> [CycleScore] {
        let trueFinal = cycle.samples.map { $0.usedPercentage }.max() ?? 0
        guard trueFinal > 0 else { return [] }
        let duration = cycle.resetsAt.timeIntervalSince(cycle.cycleStart)
        guard duration > 0 else { return [] }

        return models.compactMap { model -> CycleScore? in
            var graded: [(f: Double, err: Double)] = []
            for f in cutFractions {
                let now = cycle.cycleStart.addingTimeInterval(duration * f)
                let seen = cycle.samples.filter { $0.at <= now }
                guard seen.count >= 3 else { continue }
                let partial = PartialCycle(samples: seen, now: now,
                                           cycleStart: cycle.cycleStart, resetsAt: cycle.resetsAt)
                guard let projection = model.fit(partial) else { continue }
                graded.append((f, abs(projection(cycle.resetsAt) - trueFinal)))
            }
            guard !graded.isEmpty else { return nil }
            let mean = graded.reduce(0) { $0 + $1.err } / Double(graded.count)
            // Convergence: earliest f from which every later cut stayed within
            // tolerance. Walk from the latest cut backward while still in band.
            var convergence = 1.0
            for g in graded.sorted(by: { $0.f > $1.f }) {
                if g.err <= tolerance { convergence = g.f } else { break }
            }
            return CycleScore(modelId: model.id, meanAbsError: mean, convergenceFraction: convergence)
        }
    }

    /// Friendly display name for a model id.
    public static func displayName(_ modelId: String) -> String {
        switch modelId {
        case "linear-recent": return "Linear (recent)"
        case "recency-weighted": return "Recency-weighted"
        case "damped-acceleration": return "Damped acceleration"
        case "saturating": return "Saturating"
        default: return modelId
        }
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
