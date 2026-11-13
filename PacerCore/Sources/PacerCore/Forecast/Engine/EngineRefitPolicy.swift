import Foundation

/// How a refit backs off when the Mac is short of memory (#389).
///
/// What a refit costs a loaded Mac is mostly not its own: it is about 3 s of CPU
/// and 60 MB of transient heap, but each one also starts a live arena round of up
/// to 29 forecasts, and a large network among them re-reads up to 860 MB of mapped
/// weights once pressure has evicted them. One loaded Mac paged in 10 GB in 20
/// minutes that way. So the levers are how often a refit runs and how much it asks
/// the arena for, not what the refit itself computes.
///
/// Every deferral here is bounded: the floor is a floor, not a gate, so a Mac
/// that stays at warning all day still refits, just less often.
public enum EngineRefitPolicy {

    /// The least time between refits at this level.
    ///
    /// Warning doubles it, to ten minutes for rate-limit data, and goes no
    /// further on purpose: a five-hour window's arena line is drawn for 15
    /// minutes after it is made (`ArenaLiveCache.maxAge`), and a longer floor
    /// would blank that line between refits for the whole time a Mac sat at
    /// warning. Critical gives that up: the Mac is about to start killing things.
    public static func floor(base: TimeInterval, pressure: MemoryPressure.Level) -> TimeInterval {
        switch pressure {
        case .normal: return base
        case .warning: return base * 2
        case .critical: return base * 6
        }
    }

    /// A refit that paged in more than this (about a fifth of the mapped
    /// networks) was reading its weights back from disk: the Mac had evicted them.
    public static let heavyPageinBytes: UInt64 = 100_000_000
    /// The longest a heavy page-in stretches the floor to.
    public static let heavyFloorCap: TimeInterval = 3600

    /// `floor(base:pressure:)`, doubled (to at most an hour) when the last refit
    /// paged in a lot and the Mac is still short of memory. Refits that page in
    /// 373-489 MB every 20 minutes kept evicting the main thread's own pages;
    /// each one costs more than the one before when the weights have to come
    /// back from disk, so a Mac in that state gets fewer of them. Bounded, like
    /// every deferral here: it still refits at least hourly.
    public static func floor(base: TimeInterval, pressure: MemoryPressure.Level,
                             lastPageinBytes: UInt64) -> TimeInterval {
        let plain = floor(base: base, pressure: pressure)
        guard pressure >= .warning, lastPageinBytes > heavyPageinBytes else { return plain }
        return max(plain, min(plain * 2, heavyFloorCap))
    }

    /// Which of a window's arena models (the pick first) to make this refit.
    /// Under pressure only the pick, the one line a person is reading; at
    /// critical none, and the cached lines age out into the engine's own models.
    /// The compare sheet still draws any model on demand.
    public static func liveModels(_ ids: [String], pressure: MemoryPressure.Level) -> [String] {
        switch pressure {
        case .normal: return ids
        case .warning: return Array(ids.prefix(1))
        case .critical: return []
        }
    }

    /// The once-a-build record pass reads every archived reading of every
    /// account. It can wait for a refit that finds the Mac out of critical.
    public static func recordBackfillAllowed(pressure: MemoryPressure.Level) -> Bool {
        pressure < .critical
    }
}
