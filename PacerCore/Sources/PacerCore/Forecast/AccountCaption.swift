import Foundation

/// The one muted line under an account's bars in the menu-bar dropdown
/// (#318): only the reset and forecast facts that matter, at most two.
///
///     weekly resets in 2 days
///     weekly resets in 12 hr · limit around reset
///     weekly limit in 28 hr · 5-hour resets in 4 hr
///
/// **The rule.** Each window that is running (it has a cycle and is above
/// 0%) says one thing, ranked most urgent first:
///
///     1. at the limit                    "<w> resets in X"    soonest reset first
///     2. crosses before its reset        "<w> limit in X"     soonest crossing first
///     3. may cross (the claim withheld)  "<w> may hit limit in X"
///     4. ends at the limit at its reset  "<w> resets in X · limit around reset"
///     5. anything else                   "<w> resets in X"    the binding one only
///
/// Every window in tiers 1–4 is a reason to look, so each gets its line, the
/// most urgent first. Of the rest only the binding window speaks, the one
/// with the most used, because it is the one that stops you first; a quiet
/// window's reset is not news (a Fable cap at 2% resetting with the weekly
/// would only repeat it), and neither is its reset when a more urgent
/// window already said it in the same words. Two facts at most, so the line fits one row of a 300 pt menu;
/// tier 4's pair, when only one place is left, shortens to "<w> limit
/// around reset".
///
/// Idle windows (no cycle, or past their reset with no new reading) and
/// windows at 0% say nothing: there is nothing to reset and nothing coming.
/// The words come from `ForecastChip`, so the dropdown, the cards and the
/// notifications say a crossing the same way.
public enum AccountCaption {

    public struct Window: Sendable, Equatable {
        /// How the line names it: "5-hour", "weekly", "Fable".
        public let name: String
        /// The number shown: the live estimate or the reading.
        public let percent: Double
        /// The running cycle's reset; nil when the window is idle or past
        /// its reset.
        public let resetsAt: Date?
        /// Its forecast as the card would show it at the same instant
        /// (`ForecastChip.make`); nil for none.
        public let forecast: ForecastChip?

        public init(name: String, percent: Double, resetsAt: Date?, forecast: ForecastChip?) {
            self.name = name
            self.percent = percent
            self.resetsAt = resetsAt
            self.forecast = forecast
        }
    }

    public static let maxFacts = 2

    /// The line's facts, most urgent first.
    public static func facts(_ windows: [Window], now: Date) -> [String] {
        struct Unit {
            let tier: Int
            /// Within a tier, smaller first; then `tie`.
            let key: Double
            var tie: Double = 0
            let facts: [String]
            /// The one-fact form when only one place is left.
            let short: String
            /// The reset words it says, to say each only once.
            let resetWords: String?
        }
        var units: [Unit] = []
        for w in windows {
            guard let resets = w.resetsAt, resets > now, PacerMeterFormat.tenths(w.percent) > 0 else { continue }
            let inReset = "in " + ForecastChip.coarseEta(resets, now: now)
            let resetFact = "\(w.name) resets \(inReset)"
            let untilReset = resets.timeIntervalSince(now)
            switch w.forecast?.kind {
            case .atLimit?:
                units.append(Unit(tier: 1, key: untilReset, facts: [resetFact], short: resetFact,
                                  resetWords: inReset))
            case .limit(let at)?:
                let fact = "\(w.name) limit in \(ForecastChip.coarseEta(at, now: now))"
                units.append(Unit(tier: 2, key: at.timeIntervalSince(now), facts: [fact], short: fact,
                                  resetWords: nil))
            case .mayHitLimit(let at)?:
                let fact = "\(w.name) may hit limit in \(ForecastChip.coarseEta(at, now: now))"
                units.append(Unit(tier: 3, key: at.timeIntervalSince(now), facts: [fact], short: fact,
                                  resetWords: nil))
            case .limitAroundReset?:
                units.append(Unit(tier: 4, key: untilReset, facts: [resetFact, "limit around reset"],
                                  short: "\(w.name) limit around reset", resetWords: inReset))
            default:
                // Above 99.5 the number is the limit whatever the chip says.
                if w.percent.rounded(.down) >= 100 {
                    units.append(Unit(tier: 1, key: untilReset, facts: [resetFact], short: resetFact,
                                      resetWords: inReset))
                } else {
                    // The binding window first: the most used, then the
                    // sooner reset.
                    units.append(Unit(tier: 5, key: -w.percent, tie: untilReset, facts: [resetFact],
                                      short: resetFact, resetWords: inReset))
                }
            }
        }
        let ranked = units.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            return $0.key != $1.key ? $0.key < $1.key : $0.tie < $1.tie
        }
        var out: [String] = []
        var saidResets: Set<String> = []
        var spokeQuiet = false
        for unit in ranked {
            let room = maxFacts - out.count
            guard room > 0 else { break }
            if unit.tier == 5 {
                guard !spokeQuiet else { continue }
                spokeQuiet = true
            }
            // The binding window's reset, already said by a more urgent
            // window in the same words, is not news.
            if unit.tier == 5, let words = unit.resetWords, saidResets.contains(words) {
                continue
            }
            out += unit.facts.count <= room ? unit.facts : [unit.short]
            if let words = unit.resetWords { saidResets.insert(words) }
        }
        return out
    }

    /// The facts as one line, "a · b"; empty when there are none.
    public static func text(_ windows: [Window], now: Date) -> String {
        facts(windows, now: now).joined(separator: " · ")
    }
}
