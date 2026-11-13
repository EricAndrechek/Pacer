import Foundation
import SwiftData

/// What the data canary says, and to whom (#353). Signal list:
/// `docs/telemetry-plan.md`, "Data canary".
public extension DataCanary {

    /// The issue's message, fixed so the same upstream defect on many Macs is
    /// one Sentry issue, told apart by its tags.
    static let mismatchMessage = "Session totals disagree with Claude Code"

    /// Health counters (not usage: Sentry metrics, `counter.*` in PostHog's
    /// check-in), drained by the daily check-in.
    enum Counter {
        /// Runs that read at least one config.
        public static let runs = "data.canary.runs"
        /// Sessions judged.
        public static let checked = "data.canary.checked"
        /// Sessions judged with at least one kind out of tolerance.
        public static let mismatched = "data.canary.mismatched"
    }

    /// The problem's tags: the token kind, the ratio band, and the Claude Code
    /// version the session's turns were written by. Nothing else; a version
    /// that is not plain dotted digits is sent as `other`.
    static func problemAttributes(
        kind: SessionTotalsCanary.TokenKind, band: String, ccVersion: String?
    ) -> Telemetry.Attributes {
        [
            "canary.kind": .string(kind.rawValue),
            "canary.ratio_band": .string(band),
            "canary.cc_version": .string(enumerableVersion(ccVersion)),
        ]
    }

    static func enumerableVersion(_ version: String?) -> String {
        guard let version, !version.isEmpty else { return "unknown" }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let plain = (2...4).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        return plain ? version : "other"
    }

    /// Log, count and report one run. The log is local and may name a session
    /// by its id's first eight characters; nothing that leaves does.
    static func publish(_ report: Report, elapsed: TimeInterval? = nil) {
        for session in report.checked { Log.write("DataCanary", logLine(session)) }
        Log.write("DataCanary", summaryLine(report, elapsed: elapsed))

        guard report.configFiles > 0 else { return }
        TelemetryCounters.add(Counter.runs)
        TelemetryCounters.add(Counter.checked, report.checked.count)
        TelemetryCounters.add(Counter.mismatched, report.mismatched.count)
        for problem in problems(report) {
            Telemetry.problem(mismatchMessage, attributes: problem)
        }
    }

    /// One problem per kind and band per run: ten sessions hit by one defect
    /// are one signal, and the counters carry how many.
    static func problems(_ report: Report) -> [Telemetry.Attributes] {
        var seen = Set<String>()
        var out: [Telemetry.Attributes] = []
        for session in report.mismatched {
            for mismatch in session.comparison.mismatches
            where seen.insert("\(mismatch.kind.rawValue)|\(mismatch.band)").inserted {
                out.append(problemAttributes(kind: mismatch.kind, band: mismatch.band,
                                             ccVersion: session.ccVersion))
            }
        }
        return out
    }

    static func logLine(_ session: CheckedSession) -> String {
        let ratios = SessionTotalsCanary.TokenKind.allCases.map { kind in
            "\(kind.rawValue)=\(format(session.comparison.ratios[kind] ?? 1))"
        }.joined(separator: " ")
        let verdict = session.comparison.matched
            ? "match"
            : "MISMATCH " + session.comparison.mismatches.map {
                "\($0.kind.rawValue) \(format($0.ratio)) (\($0.band))"
            }.joined(separator: ", ")
        return "session \(session.sessionId.prefix(8)) cc \(session.ccVersion ?? "?"): "
            + "\(ratios) → \(verdict)"
    }

    static func summaryLine(_ report: Report, elapsed: TimeInterval? = nil) -> String {
        let skipped = report.skipped.sorted { $0.key < $1.key }
            .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
        var line = "run: \(report.configFiles) config(s), \(report.sessions) session(s); "
            + "checked \(report.checked.count) (mismatch \(report.mismatched.count)); "
            + "already judged \(report.alreadyJudged); skipped: \(skipped.isEmpty ? "none" : skipped)"
        if let elapsed { line += String(format: "; %.0f ms", elapsed * 1000) }
        return line
    }

    private static func format(_ ratio: Double) -> String {
        ratio.isFinite ? String(format: "%.3f", ratio) : "inf"
    }
}

/// The sessions already judged, so each is judged once (#353): the counters
/// count sessions, not runs, and a mismatch is reported once. Kept in the
/// app's defaults as id → when, and pruned once past the lookback, after
/// which `DataCanary.run` would not pick the session up anyway.
public struct DataCanaryLedger: @unchecked Sendable {
    // @unchecked: `UserDefaults` is documented thread-safe.
    public static let key = "pacer.dataCanary.judged"
    private let defaults: UserDefaults
    private let keepFor: TimeInterval

    public init(defaults: UserDefaults = PacerPreferences.store,
                keepFor: TimeInterval = SessionTotalsCanary.Policy.standard.lookback + 86_400) {
        self.defaults = defaults
        self.keepFor = keepFor
    }

    public func judged(now: Date = Date()) -> Set<String> {
        Set(entries(now: now).keys)
    }

    public func record(_ sessionIds: [String], now: Date = Date()) {
        guard !sessionIds.isEmpty else { return }
        var kept = entries(now: now)
        for id in sessionIds { kept[id] = now.timeIntervalSince1970 }
        defaults.set(kept, forKey: Self.key)
    }

    private func entries(now: Date) -> [String: Double] {
        let raw = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        let cutoff = now.timeIntervalSince1970 - keepFor
        return raw.filter { $0.value >= cutoff }
    }
}

public extension DataCanary {

    /// The scheduled run: this Mac's sources, the ledger, `run`, `publish`.
    /// Blocking; call it off the main actor.
    @discardableResult
    static func runAndPublish(
        container: ModelContainer,
        sources: Sources = .machine(),
        ledger: DataCanaryLedger = DataCanaryLedger(),
        now: Date = Date()
    ) -> Report {
        let started = Date()
        let report = run(container: container, sources: sources,
                         alreadyJudged: ledger.judged(now: now), now: now)
        ledger.record(report.checked.map(\.sessionId), now: now)
        publish(report, elapsed: Date().timeIntervalSince(started))
        return report
    }
}
