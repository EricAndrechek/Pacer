import Foundation

/// The universal answer the prediction engine returns for any quantitative
/// question — a point estimate carried together with its *honest uncertainty*.
///
/// The round-2 research verdict was blunt: on this kind of bursty, per-user
/// data the point-accuracy lifts over a naive baseline are marginal, but a
/// well-*calibrated* interval (the 80% band actually contains the truth ~80% of
/// the time) is a real, defensible, net-new win. So every surface speaks in
/// `Estimate`: a number, a band, which method produced it, how confident we are,
/// and how much of the user's own history backs it. A view renders the band and
/// can lean on it when the point is too early to trust — rather than showing a
/// confident wrong number.
///
/// Value-agnostic: `value`/bounds are dollars for cost questions, percentage
/// points for rate-limit utilisation, etc. The engine owns the meaning.
public struct Estimate: Sendable, Equatable {

    /// How much trust the point estimate has earned, driven by data sufficiency
    /// and backtest support — not by the interval width.
    public enum Confidence: String, Sendable, Equatable, Comparable, CaseIterable {
        /// Not enough history to answer; callers should show the band (or a
        /// "too early / not enough data yet" state) and suppress the point.
        case insufficient
        case low
        case medium
        case high

        private var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Confidence, b: Confidence) -> Bool { a.rank < b.rank }
    }

    /// Point estimate (best single guess).
    public let value: Double
    /// ~80% predictive interval, when the method produces calibrated bands.
    public let interval80: ClosedRange<Double>?
    /// ~50% predictive interval (the "likely" range).
    public let interval50: ClosedRange<Double>?
    /// Stable id of the model/method that produced this (for logging + a
    /// "projection method: …" affordance, and for the self-eval scoreboard).
    public let method: String
    public let confidence: Confidence
    /// Number of historical cases (days/cycles/samples) backing the estimate —
    /// the honest "how much do we actually know" counter.
    public let support: Int
    /// Optional human-readable caveat ("too early to project before noon",
    /// "only 4 completed 7-day cycles so far").
    public let note: String?

    public init(
        value: Double,
        interval80: ClosedRange<Double>? = nil,
        interval50: ClosedRange<Double>? = nil,
        method: String,
        confidence: Confidence,
        support: Int,
        note: String? = nil
    ) {
        self.value = value
        self.interval80 = interval80
        self.interval50 = interval50
        self.method = method
        self.confidence = confidence
        self.support = support
        self.note = note
    }

    /// The "we can't answer this yet" estimate — distinct from a confident zero.
    /// Carries the reason so the UI can explain the empty state.
    public static func insufficient(method: String, note: String, support: Int = 0) -> Estimate {
        Estimate(value: .nan, interval80: nil, interval50: nil,
                 method: method, confidence: .insufficient, support: support, note: note)
    }

    /// True when there isn't enough signal to show a point estimate.
    public var isInsufficient: Bool { confidence == .insufficient || value.isNaN }
}
