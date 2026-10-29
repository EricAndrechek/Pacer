import Foundation

/// Every forecaster for one meter, as the compare sheet lists them: the
/// engine's own methods and the arena models alike, ranked the same way, each
/// with what it can show now. One value, built by the engine from what it
/// already holds; the sheet reads it and nothing else, so the two halves of
/// the old sheet (drawn rows, "More models") cannot disagree.
public struct MeterModelBoard: Sendable, Equatable {
    public var windowKey: String
    /// Best first: ranked rows by typical miss, then scoring, downloading,
    /// unavailable, and the well-behind group last.
    public var rows: [Row]
    /// How far through its window the live cycle is (0…1), the point the
    /// ranking is matched to; nil with no live cycle.
    public var cutFraction: Double?
    /// The past cycles every ranked number covers (the same for every row).
    public var spanCycles: Int
    /// Grading still to do for this meter's account; nil when caught up.
    public var progress: Progress?

    public init(windowKey: String, rows: [Row], cutFraction: Double?, spanCycles: Int, progress: Progress?) {
        self.windowKey = windowKey; self.rows = rows; self.cutFraction = cutFraction
        self.spanCycles = spanCycles; self.progress = progress
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var summary: String?
        public var status: Status
        /// The model on the dashboard.
        public var isPick: Bool
        /// Drawn when the sheet opens: the pick and the next few ranked.
        public var drawnByDefault: Bool
        public var complexity: Int
        /// Ranked on the previous grading while the current one is still
        /// being filled in (a bucket-version bump): how far the new grading
        /// of this model has come. The status stays the previous grading's
        /// standing until the window switches. Nil otherwise.
        public var regrading: Regrading?
        /// Which test put a well-behind row there; nil on every other row.
        public var behind: EngineSelfEval.RLRanking.WellBehind?

        public init(id: String, name: String, summary: String?, status: Status, isPick: Bool,
                    drawnByDefault: Bool, complexity: Int, regrading: Regrading? = nil,
                    behind: EngineSelfEval.RLRanking.WellBehind? = nil) {
            self.id = id; self.name = name; self.summary = summary; self.status = status
            self.isPick = isPick; self.drawnByDefault = drawnByDefault; self.complexity = complexity
            self.regrading = regrading; self.behind = behind
        }
    }

    /// Cycles graded anew of the window's depth, and when the grader should
    /// be done with them (nil: not being graded right now, or not timed yet).
    public struct Regrading: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var eta: TimeInterval?
        public init(done: Int, total: Int, eta: TimeInterval?) {
            self.done = done; self.total = total; self.eta = eta
        }
    }

    public enum Status: Sendable, Equatable {
        /// Graded over the span: typical miss in points at the matched point
        /// of the window.
        case ranked(typicalMiss: Double, cycles: Int)
        /// Graded, but clearly behind the best; still graded on every new
        /// cycle and drawable.
        case wellBehind(typicalMiss: Double, cycles: Int)
        /// Still being graded over history.
        case scoring(done: Int, total: Int, eta: TimeInterval?)
        /// Its network is downloading (nil: progress unknown).
        case downloading(fraction: Double?)
        /// Cannot forecast this meter yet, and why ("not enough history").
        case unavailable(String)
    }

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var eta: TimeInterval?
        public init(done: Int, total: Int, eta: TimeInterval?) {
            self.done = done; self.total = total; self.eta = eta
        }
    }
}
