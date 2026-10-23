import Foundation
import Observation
import SwiftData

/// The app's one live meter (#318): every account's live values, rebuilt off
/// the main actor whenever a reading lands or new turns are scanned, for the
/// in-app surfaces to read through `LiveMeterReadout`.
///
/// **One value for every surface.** The menu bar, the window title, the pace
/// card and the model comparison each used to read the latest reading on its
/// own. Computing the live value per surface would have given each its own
/// answer a few seconds apart, the failure the PacerUI rule exists to stop,
/// and paid for the reads once per surface.
///
/// **What rebuilds it**, and nothing else:
/// - a rate-limit write (`RateLimitWriteSignal.generation`): a new reading
///   replaces the estimate;
/// - a scan cycle that wrote turns (`pacerScanCycleDidComplete` with
///   `samplesChanged`): new spend to add;
/// - the moment the earliest value expires (its reading turns an hour old,
///   or its window resets), so an idle machine does not keep showing an
///   estimate that should have stood down. One sleeping task, not a
///   periodic timer.
///
/// No `@Query`: always-mounted surfaces read this, and a `@Query` re-fetches
/// on every save (AGENTS.md). Builds are coalesced (one in flight, one
/// queued) and each runs on its own `ModelContext` in a detached task, with
/// only `Sendable` values crossing back. Per account it is a fit probe per
/// window, the readings of the last hour, and the turns since: a few
/// milliseconds (`LiveMeterProbe.timeSnapshotReads`).
///
/// **Published only on a change a surface can show.** A rebuild on every
/// scan cycle that left every number where it was would otherwise redraw
/// the menu bar's status item each time (`asOf` alone always moves).
///
/// **Never stored.** The values live here and nowhere else: not in the
/// store, the archive, the engine's training or scoring, or `RecentBurn`.
@MainActor
@Observable
public final class LiveMeterBoard {

    public static let shared = LiveMeterBoard()

    /// Account → window key → live value. Only accounts and windows that
    /// have one: no fit, a weak fit, or a reading over an hour old have none.
    public private(set) var values: [String: [String: LiveMeterValue]] = [:]

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var writeWatch: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var pending = false
    /// Bumped by `start` and `stop`, so a build that straddles one is dropped.
    @ObservationIgnored private var epoch: UInt64 = 0

    private init() {}

    // MARK: - Reading

    /// The live value for one account's window, if there is one.
    public func value(account: String?, window: String) -> LiveMeterValue? {
        guard let account else { return nil }
        return values[account]?[window]
    }

    /// What a surface holding `reading` shows for this window at `now`.
    public func readout(account: String?, window: String, reading: MeterReading,
                        now: Date = Date()) -> LiveMeterReadout {
        LiveMeterReadout(reading: reading, live: value(account: account, window: window), now: now)
    }

    // MARK: - Lifecycle

    /// Start rebuilding from `container`. Idempotent per container.
    public func start(container: ModelContainer) {
        stop()
        self.container = container
        epoch &+= 1
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .pacerScanCycleDidComplete, object: nil, queue: .main) { note in
                let summary = note.object as? ScanCycleSummary
                // Rate-limit writes arrive through the write signal below;
                // this one is for turns.
                guard summary?.samplesChanged ?? true else { return }
                MainActor.assumeIsolated { LiveMeterBoard.shared.refresh() }
            },
        ]
        writeWatch = Task { @MainActor in
            while !Task.isCancelled {
                await Self.nextRateLimitWrite()
                guard !Task.isCancelled else { return }
                LiveMeterBoard.shared.refresh()
            }
        }
        refresh()
    }

    /// Stop and forget every value: nothing rebuilds them any more.
    public func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        writeWatch?.cancel()
        writeWatch = nil
        expiry?.cancel()
        expiry = nil
        deferred?.cancel()
        deferred = nil
        container = nil
        epoch &+= 1
        pending = false
        if !values.isEmpty { values = [:] }
    }

    /// Ask for a rebuild. Coalesced: a request while one runs becomes one
    /// more after it.
    public func refresh() {
        guard let container else { return }
        pending = true
        guard !inFlight else { return }
        inFlight = true
        let started = epoch
        Task { @MainActor in
            repeat {
                pending = false
                let now = Date()
                let built = await Task.detached(priority: .utility) {
                    Self.build(container: container, now: now)
                }.value
                guard started == epoch else { break }
                publish(built)
            } while pending && started == epoch
            inFlight = false
            // A restart while this ran: its own request is still owed.
            if pending, started != epoch { refresh() }
        }
    }

    // MARK: - Build

    /// Every account's live values at `now`, on a context of its own. Pure
    /// reads; safe off the main actor.
    public nonisolated static func build(container: ModelContainer,
                                         now: Date) -> [String: [String: LiveMeterValue]] {
        let context = ModelContext(container)
        let names = Set(context.container.schema.entities.map(\.name))
        guard names.contains(Schema.entityName(for: Account.self)) else { return [:] }
        let accounts = ((try? context.fetch(FetchDescriptor<Account>())) ?? [])
            .map(\.id).filter { $0 != AccountDailyAggregate.unattributedKey }
        let source = LiveMeterSource(context: context)
        var out: [String: [String: LiveMeterValue]] = [:]
        for account in accounts {
            let values = source.currentValues(account: account, now: now)
            if !values.isEmpty { out[account] = values }
        }
        return out
    }

    /// Swap in `built` when anything a surface shows differs, and arm the
    /// expiry for the earliest value.
    ///
    /// A change in the tenths alone (`sameWhole`) is published at most every
    /// `tenthsInterval`. While an account is busy the estimate's decimal
    /// moves on nearly every scan cycle (every few seconds), and each publish
    /// redraws every surface reading the board, the pace card's charts among
    /// them, on a dashboard that stays open. A new reading, a whole point,
    /// or the number turning into (or out of) an estimate is published at
    /// once.
    private func publish(_ built: [String: [String: LiveMeterValue]]) {
        armExpiry(built)
        deferred?.cancel()
        deferred = nil
        guard !Self.sameOnScreen(values, built) else { return }
        let now = Date()
        let since = lastPublished.map { now.timeIntervalSince($0) } ?? .infinity
        guard Self.sameWhole(values, built), since < Self.tenthsInterval else {
            values = built
            lastPublished = now
            return
        }
        deferred = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.tenthsInterval - since))
            guard !Task.isCancelled else { return }
            LiveMeterBoard.shared.values = built
            LiveMeterBoard.shared.lastPublished = Date()
        }
    }

    /// The least time between two publishes that only move a tenth.
    nonisolated static let tenthsInterval: TimeInterval = 15

    @ObservationIgnored private var lastPublished: Date?
    @ObservationIgnored private var deferred: Task<Void, Never>?

    /// Equal in everything but the shown tenths: a publish this would allow
    /// is held to `tenthsInterval`.
    nonisolated static func sameWhole(_ a: [String: [String: LiveMeterValue]],
                                      _ b: [String: [String: LiveMeterValue]]) -> Bool {
        guard a.keys == b.keys else { return false }
        for (account, x) in a {
            guard let y = b[account], x.keys == y.keys else { return false }
            for (key, v) in x {
                guard let w = y[key], v.percent == w.percent, v.isEstimate == w.isEstimate,
                      v.reading == w.reading, v.restarted == w.restarted else { return false }
            }
        }
        return true
    }

    /// Equal in everything a readout reads: the whole and the shown number,
    /// whether it is an estimate, the reading under it, and whether it
    /// restarted. The shown tenth moves with each scan cycle's spend, so a
    /// busy account republishes about that often; an idle one, never.
    nonisolated static func sameOnScreen(_ a: [String: [String: LiveMeterValue]],
                                         _ b: [String: [String: LiveMeterValue]]) -> Bool {
        guard a.keys == b.keys else { return false }
        for (account, x) in a {
            guard let y = b[account], x.keys == y.keys else { return false }
            for (key, v) in x {
                guard let w = y[key], v.percent == w.percent, v.shownPercent == w.shownPercent,
                      v.isEstimate == w.isEstimate, v.reading == w.reading,
                      v.restarted == w.restarted else { return false }
            }
        }
        return true
    }

    /// The next instant a value stops applying with nothing written: its
    /// reading turning `LiveMeter.maxReadingAge` old, or its window resetting.
    nonisolated static func nextExpiry(_ values: [String: [String: LiveMeterValue]], after now: Date) -> Date? {
        values.values.flatMap(\.values).flatMap { v -> [Date] in
            // The anchor is the reading itself, or the earlier tick a stale
            // reading held at: the value lasts an hour from that.
            var out = [v.anchor.at.addingTimeInterval(LiveMeter.maxReadingAge)]
            if let reset = v.reading.resetsAt, !v.restarted { out.append(reset) }
            return out
        }
        .filter { $0 > now }
        .min()
    }

    private func armExpiry(_ built: [String: [String: LiveMeterValue]]) {
        expiry?.cancel()
        guard let at = Self.nextExpiry(built, after: Date()) else { return }
        expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(1, at.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            LiveMeterBoard.shared.refresh()
        }
    }

    /// Resumes at the next rate-limit write.
    private static func nextRateLimitWrite() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = RateLimitWriteSignal.shared.generation
            } onChange: {
                continuation.resume()
            }
        }
    }
}
