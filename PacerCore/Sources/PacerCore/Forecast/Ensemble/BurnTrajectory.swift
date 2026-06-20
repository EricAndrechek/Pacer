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

    /// A drop of at least this many utilisation points, landing at or below
    /// `resetLowMax`, marks an *off-schedule reset* inside one anchor's samples.
    /// Within a real cycle utilisation is monotone non-decreasing, so only a
    /// reset produces that. (The companion to `GlobalRateLimitReset.detect`,
    /// reading the value drop the dropped null-anchor samples leave behind.)
    static let resetDropPoints: Double = 15
    static let resetLowMax: Double = 5

    /// First index *after* the last in-cycle reset, or 0 when the run never
    /// resets. Used to keep only the post-reset tail of a contaminated cycle.
    static func postResetStartIndex(
        _ rows: [(at: Date, usedPercentage: Double, resetsAt: Date)]
    ) -> Int {
        guard rows.count > 1 else { return 0 }
        var split = 0
        for i in 1..<rows.count where
            rows[i - 1].usedPercentage - rows[i].usedPercentage >= resetDropPoints
            && rows[i].usedPercentage <= resetLowMax {
            split = i
        }
        return split
    }

    /// Segment a flat run of samples (each carrying its window's `resetsAt`)
    /// into the current partial cycle and the prior complete cycles, by
    /// grouping on the reset boundary. The group whose reset is latest is the
    /// current cycle; the rest are history for the backtest. `duration` is the
    /// window length (5h or 7d). Order-agnostic.
    ///
    /// Reset-aware: an off-schedule global reset can zero a window mid-cycle
    /// while leaving its `resetsAt` anchor unchanged (Anthropic restored the
    /// same 7-day anchor on 2026-06-20), which would otherwise fuse the pre-
    /// and post-reset readings into one NON-MONOTONE cycle — distorting the live
    /// fit (a bogus negative slope, an under-scaled level, the wrong band
    /// stratum) and poisoning the completed-cycle backtest the engine learns
    /// from. We keep only the post-reset tail of such a group and re-anchor its
    /// start to the reset, so every cycle handed downstream is monotone from
    /// its own start.
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
        for (key, rowsRaw) in groups {
            let rows = rowsRaw.sorted { $0.at < $1.at }
            // Drop the pre-reset prefix of a contaminated cycle.
            let split = postResetStartIndex(rows)
            let kept = Array(rows[split...])
            guard !kept.isEmpty else { continue }
            // Use the real reset from the readings, not the rounded group key.
            let reset = kept.map { $0.resetsAt }.max() ?? key
            // A reset restarts the budget at the drop edge (the last reading
            // before the collapse ≈ the reset instant, and a safe lower bound
            // on it); an unbroken cycle begins one window-length before reset.
            let cycleStart = split > 0 ? rows[split - 1].at : reset.addingTimeInterval(-duration)
            let cycleSamples = kept.map { Sample(at: $0.at, usedPercentage: $0.usedPercentage) }
            if key == currentReset {
                current = PartialCycle(samples: cycleSamples, now: now, cycleStart: cycleStart, resetsAt: reset)
            } else {
                history.append(Cycle(samples: cycleSamples, cycleStart: cycleStart, resetsAt: reset))
            }
        }
        return (current, history.sorted { $0.cycleStart < $1.cycleStart })
    }

    /// One model's forward trajectory plus its realized accuracy — for the
    /// "show all models" detail view. Built by the engine
    /// (`UsageIntelligenceEngine.rateLimitTrajectories`), which pairs each
    /// candidate with its accuracy from the persisted per-user track record.
    public struct ScoredTrajectory: Sendable, Identifiable {
        public let modelId: String
        public let complexity: Int
        public let trajectory: Trajectory
        /// Median absolute error (percentage points) against the realized
        /// final of completed cycles. `.infinity` when there's no record yet.
        public let medianAbsError: Double
        public let coverage: Double
        public let isSelected: Bool
        public var id: String { modelId }
    }

    /// Friendly display name for a model id.
    public static func displayName(_ modelId: String) -> String {
        switch modelId {
        case "linear-recent": return "Linear (recent)"
        case "recency-weighted": return "Recency-weighted"
        case "damped-acceleration": return "Damped acceleration"
        case "saturating": return "Saturating"
        case "diurnal-rate": return "Your daily rhythm"
        default: return modelId
        }
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
