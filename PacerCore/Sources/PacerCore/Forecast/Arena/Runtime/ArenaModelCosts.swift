import Foundation

/// What one forecast of each arena model costs, in CPU milliseconds on the
/// scorer's thread: an exponential moving average per model and window scale,
/// kept across launches, so the scorer can do the cheap models first
/// (`ArenaRecordScorer`, phase 1) and leave the heavy ones for after.
///
/// **Why order by cost.** A first launch scores two dozen models over months
/// of cycles inside a fifth of one core. A few networks and the ensembles over
/// them cost seconds a forecast; most of the rest cost milliseconds. Scored
/// together, cycle by cycle, the cheap models' records grew at the heavy
/// ones' pace: 61 of 413 cycles in 8.7 hours on a heavy store, so almost
/// nothing had the cycles behind it selection needs
/// (`EngineSelfEval.rlMinPeriods`) and the user saw no difference for
/// days. The cheap ones alone cover the same history in a small fraction of
/// that.
///
/// **CPU, not wall time.** The scorer sleeps inside a forecast to stay within
/// its budget (`ArenaCPUBudget`), so wall time is mostly the budget's own
/// pacing. Thread CPU time is exact here because BLAS runs on the calling
/// thread while the runtime runs (`ArenaRuntime.init`).
///
/// **A model's first forecast on a runner is not counted.** It pays for what
/// the runner's memo then holds (a calibration layer's child backtests over
/// 24 origins, a network's first page-in), which can be twenty times a warm
/// forecast; counting it would send a model that is cheap in steady state to
/// the heavy phase on its first try.
public final class ArenaModelCosts: @unchecked Sendable {

    /// Where the averages are kept; nil keeps them for the process only
    /// (tests, probes).
    private let defaults: UserDefaults?
    public static let defaultsKey = "PacerArenaModelCPUms.v1"
    /// The weight of a new forecast in the average: about the last ten.
    static let alpha = 0.1

    private let lock = NSLock()
    /// "name|5h" or "name|wk" → (average CPU ms, forecasts counted).
    private var averages: [String: (ms: Double, n: Int)] = [:]
    private var dirty = false

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        guard let stored = defaults?.dictionary(forKey: Self.defaultsKey) as? [String: [Double]] else { return }
        for (k, v) in stored where v.count == 2 && v[0].isFinite && v[0] >= 0 {
            averages[k] = (v[0], Int(v[1]))
        }
    }

    /// Kept in the app's preferences (a test process gets a private suite,
    /// `PacerPreferences.store`).
    public static func persisted() -> ArenaModelCosts { ArenaModelCosts(defaults: PacerPreferences.store) }

    static func key(_ name: String, weekly: Bool) -> String { "\(name)|\(weekly ? "wk" : "5h")" }

    /// The measured average, or nil when this model has not been timed at
    /// this scale.
    public func measured(_ name: String, weekly: Bool) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return averages[Self.key(name, weekly: weekly)]?.ms
    }

    /// The measured average, else the prior.
    public func cost(_ spec: ArenaModelSpec, weekly: Bool, registry: [String: ArenaModelSpec]) -> Double {
        measured(spec.name, weekly: weekly) ?? Self.prior(spec, registry: registry)
    }

    /// One warm forecast's CPU time.
    public func record(_ name: String, weekly: Bool, cpuMs: Double) {
        guard cpuMs.isFinite, cpuMs >= 0 else { return }
        let k = Self.key(name, weekly: weekly)
        lock.lock(); defer { lock.unlock() }
        if let e = averages[k] {
            averages[k] = (e.ms + Self.alpha * (cpuMs - e.ms), e.n + 1)
        } else {
            averages[k] = (cpuMs, 1)
        }
        dirty = true
    }

    /// Write the averages out, when anything changed.
    public func save() {
        lock.lock()
        guard dirty, let defaults else { lock.unlock(); return }
        dirty = false
        let out = averages.mapValues { [$0.ms, Double($0.n)] }
        lock.unlock()
        defaults.set(out, forKey: Self.defaultsKey)
    }

    // MARK: - The prior

    /// A model never timed on this Mac: conservative, so a model that may
    /// be heavy waits for phase 2 rather than slowing phase 1 for everyone.
    /// Arithmetic models are a few milliseconds; a network under 123M
    /// parameters (the bundled Timestral sizes, Chronos-2) tens; one of 123M
    /// or more seconds; a parent pays for its children, twice over (its
    /// child backtests run more than one child forecast a cut).
    public static func prior(_ spec: ArenaModelSpec, registry: [String: ArenaModelSpec]) -> Double {
        var visiting = Set<String>()
        func walk(_ s: ArenaModelSpec) -> Double {
            guard visiting.insert(s.name).inserted else { return 0 }
            defer { visiting.remove(s.name) }
            var own = arithmeticPriorMs
            for w in s.weights {
                let size = networkMillions(w) ?? 0
                own = max(own, size >= bigNetworkMillions ? bigNetworkPriorMs : smallNetworkPriorMs)
            }
            let children = s.children.compactMap { registry[$0] }.reduce(0) { $0 + walk($1) }
            return own + 2 * children
        }
        return walk(spec)
    }

    static let arithmeticPriorMs = 10.0
    static let smallNetworkPriorMs = 100.0
    static let bigNetworkPriorMs = 3000.0
    static let bigNetworkMillions = 123

    /// 5, 123, 200 from `mistralai/Timestral-5M@…`, `google/timesfm-2.5-200m-pytorch@…`:
    /// the first `<digits>m` part of the repository name; nil when it names
    /// no size (`amazon/chronos-2`, 120M, counted as small).
    static func networkMillions(_ weightsId: String) -> Int? {
        let repo = weightsId.split(separator: "@").first.map(String.init) ?? weightsId
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        for part in name.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }) {
            guard part.hasSuffix("m"), part.count >= 2, let n = Int(part.dropLast()) else { continue }
            return n
        }
        return nil
    }
}
