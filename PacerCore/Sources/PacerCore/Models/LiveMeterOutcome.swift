import Foundation
import SwiftData

/// What the live meter showed for one window the moment before a real reading
/// of it landed, beside that reading (#352). One row per window per reading,
/// for every window that had a live value then: a strong fit, and a reading
/// before this one under an hour old. Written in the save that writes the
/// reading (`OAuthPoller.recordPoll`), so the two land together or not at all.
///
/// **Why it is stored.** The live value (`LiveMeterValue`) is an estimate, not
/// a reading, and until this table the only trace of it was the `[LiveMeter]`
/// drift line, which rotates out of the log after about a day and a half. How
/// far the estimate ran from the reading that replaced it, and how the fit's
/// rates did against what was actually on screen, could only be replayed with
/// today's fit and today's prices, never read back as it was.
///
/// **A record, not a reading.** Nothing draws, forecasts, alerts or trains on
/// it: no `@Query` reads it, and the engine, the archive and `RecentBurn` never
/// see it. It is there for measuring the live meter and tuning its fit.
///
/// **Kept forever**, like the readings beside it. At most one row per window
/// per reading, a few hundred bytes with its index: on a four-account install
/// polled through several tokens, about as many rows a day as
/// `RateLimitSample` gets (~2,200).
///
/// **Joins.** The reading itself is the `RateLimitSample` (a fixed window) or
/// `UsageLimitSample` (a scoped identity) with this `accountId`, the same
/// window and `sampledAt == readingAt`: both are stamped from one snapshot in
/// one save. The fit is the `SpendMeterFit` keyed
/// `SpendMeterFit.makeKey(accountId:window:fittedDay: fitDay)`, which a refit
/// on the same day replaces. Cycle membership goes through
/// `RateLimitCycle.contains` on `readingResetsAt`, never `==` (AGENTS.md
/// rule 9).
///
/// A new table of plain and optional columns: a lightweight migration.
@Model
public final class LiveMeterOutcome {
    // "One account's window over time" is the read a study makes. Nothing in
    // the app reads the table, and an export reads all of it, so there is no
    // time-only index: each index entry repeats the account id, and on a busy
    // install this table grows by a couple of thousand rows a day.
    #Index<LiveMeterOutcome>([\.accountId, \.window, \.readingAt])

    /// `Account.id`.
    public var accountId: String
    /// `five_hour`, `seven_day`, or a scoped `limits[]` identity: the
    /// `SpendMeterFit.window` key.
    public var window: String

    // MARK: The reading that landed

    public var readingAt: Date
    public var readingPercent: Double
    public var readingResetsAt: Date?

    // MARK: The reading the value was built on

    /// The window's reading before this one: the one every surface held while
    /// the value was shown (`LiveMeterValue.reading`).
    public var previousAt: Date
    public var previousPercent: Double
    /// Whether this reading is in the previous one's cycle
    /// (`LiveMeter.sameCycle`, through `RateLimitCycle.contains`).
    public var sameCycle: Bool

    // MARK: What the live meter showed

    /// The number a surface showed (`LiveMeterValue.shownPercent`): the
    /// estimate to one decimal, or the previous reading whole when nothing had
    /// moved it. Not shown when `runaway` is `suspended`; see there.
    public var shownPercent: Double
    /// The whole points the `pacer` gate and threshold alerts judged
    /// (`LiveMeterValue.percent`).
    public var livePercent: Double
    /// The estimate before flooring (`LiveMeterValue.exactPercent`).
    public var exactPercent: Double
    /// Σ rate × spend since the reading it was built on, before flooring and
    /// capping: the fit's own prediction of the rise.
    public var exactAdded: Double
    /// Where inside its whole point the meter was taken to sit at that reading
    /// (`LiveMeter.carry`).
    public var carry: Double
    /// API-list dollars counted since that reading (or the reset) through
    /// `readingAt`, priced as the fit was.
    public var spendUSD: Double
    /// `LiveMeterValue.RateSource`: per-model, pooled, mixed or none.
    public var rateSource: String
    /// The previous reading's cycle had reset by `readingAt`, so the value
    /// restarted at 0 plus the spend after the reset.
    public var restarted: Bool
    /// The `SpendMeterFit.fittedDay` whose rates built the value: the fit id,
    /// with `accountId` and `window`.
    public var fitDay: String

    // MARK: The guards

    /// The lag guard on the value: when the previous reading held still while
    /// the spend since the reading that last moved implied 2+ points
    /// (`LiveMeter.heldTick`), the value was built on that earlier reading,
    /// and this is the points the spend implied. Nil when it was built on the
    /// previous reading itself.
    public var heldImplied: Double?
    /// That earlier reading's time. Nil with `heldImplied`.
    public var heldAt: Date?
    /// The lag guard on the reading that landed: the points the spend implied
    /// while it held at the last tick's value, when it judged it stale. Nil
    /// when the reading is believed.
    public var readingHeldImplied: Double?
    /// The runaway guard's verdict on this reading
    /// (`LiveMeterRunaway.Verdict.raw`): `fine`, `high-<n>` (that many in a
    /// row), `suspended-now` (this reading tripped it; the value had been
    /// shown), `suspended` (already suspended on this fit: surfaces showed the
    /// reading, not this value), or `skipped` (a stale reading is not judged).
    public var runaway: String

    public init(accountId: String, window: String, reading: MeterReading, value: LiveMeterValue,
                sameCycle: Bool, readingHeldImplied: Double?, runaway: String) {
        self.accountId = accountId
        self.window = window
        self.readingAt = reading.at
        self.readingPercent = reading.percent
        self.readingResetsAt = reading.resetsAt
        self.previousAt = value.reading.at
        self.previousPercent = value.reading.percent
        self.sameCycle = sameCycle
        self.shownPercent = value.shownPercent
        self.livePercent = value.percent
        self.exactPercent = value.exactPercent
        self.exactAdded = value.exactAdded
        self.carry = value.carry
        self.spendUSD = value.spendUSD
        self.rateSource = value.rateSource.rawValue
        self.restarted = value.restarted
        self.fitDay = value.fittedDay
        // `LiveMeter.value` sets `heldImplied` exactly when the anchor is not
        // the reading.
        self.heldImplied = value.heldImplied
        self.heldAt = value.heldImplied != nil ? value.anchor.at : nil
        self.readingHeldImplied = readingHeldImplied
        self.runaway = runaway
    }

    /// One row per window of `measurements` that had a live value; none for
    /// the rest.
    static func rows(account: String, measurements: [LiveMeterDrift.Measurement]) -> [LiveMeterOutcome] {
        measurements.compactMap { m in
            guard let value = m.value else { return nil }
            return LiveMeterOutcome(accountId: account, window: m.window, reading: m.reading, value: value,
                                    sameCycle: m.sameCycle ?? false, readingHeldImplied: m.readingHeldImplied,
                                    runaway: (m.runaway ?? .fine).raw)
        }
    }

    /// Whether `context`'s schema has this table. A reduced test schema may
    /// not, and inserting a type the schema lacks traps.
    static func isRegistered(in context: ModelContext) -> Bool {
        let name = Schema.entityName(for: LiveMeterOutcome.self)
        return context.container.schema.entities.contains { $0.name == name }
    }
}
