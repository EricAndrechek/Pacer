import Foundation
import SwiftData

/// The runaway guard (#318): a live value that came in `highBy` points or
/// more above the next reading on `consecutive` readings in a row is
/// suspended for that account and window until the next daily fit, and the
/// window shows its readings.
///
/// What it is for is a fault, not noise: turns attributed to the wrong
/// account, or a fit that no longer describes the allowance. Either makes the
/// estimate climb ahead of the meter reading after reading, and the reading
/// keeps correcting it down. Ordinary error does not do that three times
/// running: on the one-login replay the value just before a reading was 2+
/// points high in 0.2% of busy readings.
///
/// **The reading always wins when it arrives.** Each reading already replaces
/// the estimate; this only stops the estimate from being shown again on the
/// same fit once it has proved wrong. A new daily fit (`SpendMeterFit
/// .fittedDay` moves on) lifts the suspension and starts the count over.
///
/// A reading the lag guard judged stale (`LiveMeter.heldTick`) is not an
/// answer yet, so it neither counts nor clears the count; past
/// `LiveMeter.maxServerLag` it is believed and counts like any other.
///
/// **Where it lives.** The count is in memory, judged once per reading by the
/// drift log in the app (`LiveMeterDrift.log`). The suspension is one
/// `ClaudeCodeMeta` row per window, `liveMeter.suspended|<account>|<window>`
/// holding the fit's day, so every process that builds a live value from the
/// store (the app, the widgets, `pacer` reading Pacer's data directly) sees
/// it. Written once when it trips, never per reading.
public final class LiveMeterRunaway: @unchecked Sendable {

    public static let shared = LiveMeterRunaway()

    /// How far over the next reading the estimate must come in to count.
    public static let highBy = 2.0
    /// How many readings in a row.
    public static let consecutive = 3

    static let keyPrefix = "liveMeter.suspended|"
    static func key(account: String, window: String) -> String { "\(keyPrefix)\(account)|\(window)" }

    public enum Verdict: Equatable, Sendable {
        /// Within `highBy` of the reading: the count starts over.
        case fine
        /// High, this many readings in a row so far.
        case high(Int)
        /// High for the `consecutive`th reading: suspended from now.
        case suspendedNow
        /// Already suspended on this fit.
        case suspended
        /// A stale reading: not judged.
        case skipped
    }

    private let lock = NSLock()
    private var misses: [String: (fittedDay: String, count: Int)] = [:]

    public init() {}

    /// Judge one reading against the whole-point estimate shown just before
    /// it, and on the `consecutive`th miss in a row write the suspension to
    /// `context`.
    public func judge(context: ModelContext, account: String, window: String, fittedDay: String,
                      shown: Double, reading: Double, readingIsStale: Bool) -> Verdict {
        let key = Self.key(account: account, window: window)
        if Self.suspendedDays(context: context, account: account)[window] == fittedDay { return .suspended }
        if readingIsStale { return .skipped }
        let verdict: Verdict
        lock.lock()
        var entry: (fittedDay: String, count: Int) = misses[key].flatMap { $0.fittedDay == fittedDay ? $0 : nil } ?? (fittedDay, 0)
        if shown >= reading + Self.highBy {
            entry.count += 1
            verdict = entry.count >= Self.consecutive ? .suspendedNow : .high(entry.count)
        } else {
            entry.count = 0
            verdict = .fine
        }
        misses[key] = verdict == .suspendedNow ? nil : entry
        lock.unlock()
        if verdict == .suspendedNow {
            Self.writeSuspension(context: context, key: key, fittedDay: fittedDay)
        }
        return verdict
    }

    /// Window → the fit day it is suspended on, for one account. One fetch.
    static func suspendedDays(context: ModelContext, account: String) -> [String: String] {
        guard Set(context.container.schema.entities.map(\.name))
            .contains(Schema.entityName(for: ClaudeCodeMeta.self)) else { return [:] }
        let prefix = "\(keyPrefix)\(account)|"
        let rows = (try? context.fetch(FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate { $0.key.starts(with: prefix) }))) ?? []
        return Dictionary(rows.map { (String($0.key.dropFirst(prefix.count)), $0.value) },
                          uniquingKeysWith: { a, _ in a })
    }

    private static func writeSuspension(context: ModelContext, key: String, fittedDay: String) {
        let rows = (try? context.fetch(FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == key }))) ?? []
        if let row = rows.first { row.value = fittedDay } else { context.insert(ClaudeCodeMeta(key: key, value: fittedDay)) }
        try? context.save()
    }
}
