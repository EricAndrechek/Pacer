import Foundation
import Synchronization

/// "At most N of these per Mac per UTC day", for everything that can reach
/// Sentry. One layer, applied in the Sentry hooks (`beforeSend`,
/// `tracesSampler`, `beforeSendMetric`) and on the two paths that bypass them
/// (the CLI's feedback POST, the app's crash-report forwarder).
///
/// **Why it exists**: the Sentry DSN is public (it ships in the binary) and the
/// free plan has no server-side per-key rate limit (that is Business-only), so
/// any one install, or anyone who copies the DSN out of the app, could burn
/// the month's quota. The caps bound what one honest Mac can send; they do not
/// stop someone replaying the DSN by hand. The numbers and their reasons are
/// in `Limits`.
///
/// **Cost**: a lock and a dictionary lookup per check. State is persisted in
/// the App Group defaults (so a relaunch loop cannot reset it): at once for the
/// rare kinds (errors, hangs, crashes...), at most every `persistInterval`
/// for the high-volume ones (metrics, transactions), and on `flush()`.
///
/// **What is dropped is counted**: `telemetry.capped.<kind>` in
/// `TelemetryCounters`, which the daily check-in drains, so the dashboard sees
/// capping. The check-in itself (its transaction and `checkin.*` metrics) is
/// never capped (`isExemptTransaction`, `isExemptMetric`).
public final class TelemetryBudget: @unchecked Sendable {  // UserDefaults is thread-safe

    public enum Kind: String, Sendable, CaseIterable {
        /// Error events other than crashes and hangs.
        case error
        case hang
        /// Fatal events, including forwarded widget and CLI crash reports.
        case crash
        /// MetricKit diagnostics (hang, CPU, disk-write).
        case diagnostic
        case feedback
        /// Root transactions.
        case transaction
        /// Any one metric name.
        case metric
        /// `main_thread.stall_ms`, which has its own, tighter cap.
        case stall = "stall_ms"
        /// Slow-scan traces (a transaction with an extra, tighter cap).
        case slowScan = "slow_scan"
        /// PostHog events, all names together.
        case analytics
        /// PostHog events of one name (`take(.analyticsEvent, name:)`).
        case analyticsEvent = "analytics_event"
    }

    /// Per Mac, per UTC day. Each number is a worst case that is still a small
    /// share of the free plan (5k errors, 5M spans, metrics in the millions a
    /// month) if every active Mac hit it; a healthy Mac sends a fraction.
    public struct Limits: Sendable, Equatable {
        /// Errors are the scarce quota (~5k a month): 25 a day is generous for
        /// a Mac that is genuinely broken, and 200 Macs at it would be a month.
        public var error: Int
        /// A hang can repeat for as long as the Mac is struggling.
        public var hang: Int
        /// A crash loop sends one per launch; 10 shows the loop without
        /// feeding it.
        public var crash: Int
        public var diagnostic: Int
        /// A person typing, so five is already unusual.
        public var feedback: Int
        /// The check-in (exempt) plus rebuilds, slow scans, engine passes.
        public var transaction: Int
        /// Per metric name, so one noisy name cannot starve the rest.
        public var metric: Int
        /// The noisiest name by far: ~14,000 in a week from one Debug Mac.
        public var stall: Int
        public var slowScan: Int
        /// PostHog events per day, all names. PostHog's free tier is 1M
        /// events a month; 500 a day is ~15k a month per Mac at the very
        /// worst, and a typical day is a few dozen.
        public var analytics: Int
        /// PostHog events of any one name, so one busy surface cannot use
        /// the whole day.
        public var analyticsEvent: Int
        /// The names people repeat most (`hotAnalyticsEvents`).
        public var analyticsHotEvent: Int

        public init(error: Int, hang: Int, crash: Int, diagnostic: Int, feedback: Int,
                    transaction: Int, metric: Int, stall: Int, slowScan: Int,
                    analytics: Int, analyticsEvent: Int, analyticsHotEvent: Int) {
            self.error = error; self.hang = hang; self.crash = crash
            self.diagnostic = diagnostic; self.feedback = feedback
            self.transaction = transaction; self.metric = metric; self.stall = stall
            self.slowScan = slowScan; self.analytics = analytics
            self.analyticsEvent = analyticsEvent; self.analyticsHotEvent = analyticsHotEvent
        }

        public static let release = Limits(
            error: 25, hang: 10, crash: 10, diagnostic: 10, feedback: 5,
            transaction: 150, metric: 300, stall: 100, slowScan: 20,
            analytics: 500, analyticsEvent: 100, analyticsHotEvent: 200)
        /// Debug builds are a developer's own Mac running every experiment:
        /// tighter, so they stay out of the quota.
        public static let debug = Limits(
            error: 10, hang: 3, crash: 5, diagnostic: 10, feedback: 5,
            transaction: 40, metric: 60, stall: 20, slowScan: 20,
            analytics: 100, analyticsEvent: 30, analyticsHotEvent: 50)

        func limit(for kind: Kind) -> Int {
            switch kind {
            case .error: error
            case .hang: hang
            case .crash: crash
            case .diagnostic: diagnostic
            case .feedback: feedback
            case .transaction: transaction
            case .metric: metric
            case .stall: stall
            case .slowScan: slowScan
            case .analytics: analytics
            case .analyticsEvent: analyticsEvent
            }
        }
    }

    /// The daily check-in's transaction op and metric prefix: never capped.
    public static let checkInTransactionOp = "pacer.checkin"
    public static let checkInMetricPrefix = "checkin."
    /// The metric with its own cap.
    public static let stallMetric = "main_thread.stall_ms"

    public static func isExemptTransaction(op: String) -> Bool { op == checkInTransactionOp }

    /// PostHog events that are never capped: one a day each by construction.
    public static let exemptAnalyticsEvents: Set<String> = ["daily_checkin", "widget_inventory"]
    /// PostHog events with the higher per-name cap.
    public static let hotAnalyticsEvents: Set<String> = ["tab_viewed", "menubar_opened"]
    public static func isExemptMetric(_ name: String) -> Bool { name.hasPrefix(checkInMetricPrefix) }

    static let defaultsKey = "pacer.telemetry.budget"

    private struct State {
        var limits: Limits
        var day = -1
        var counts: [String: Int] = [:]
        var loaded = false
        var dirty = false
        var lastPersist = Date.distantPast
    }

    private let store: UserDefaults
    private let now: @Sendable () -> Date
    private let persistInterval: TimeInterval
    private let state: Mutex<State>

    /// The app's one budget. Release limits until `useLimits` says otherwise.
    public static let shared = TelemetryBudget(store: PacerPreferences.store, limits: .release)

    public init(store: UserDefaults, limits: Limits,
                persistInterval: TimeInterval = 10,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        self.persistInterval = persistInterval
        self.state = Mutex(State(limits: limits))
    }

    /// Debug builds call this once at start (`#if DEBUG` lives in the app).
    public func useLimits(_ limits: Limits) { state.withLock { $0.limits = limits } }

    /// True and counted when the kind (or, for `.metric`, the metric name) is
    /// under today's limit. False records `telemetry.capped.<kind>`.
    public func take(_ kind: Kind, name: String? = nil) -> Bool {
        let key = name.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue
        let (allowed, persist) = state.withLock { s -> (Bool, Bool) in
            roll(&s)
            guard s.counts[key, default: 0] < s.limits.limit(for: kind) else { return (false, false) }
            s.counts[key, default: 0] += 1
            s.dirty = true
            let rare = kind != .metric && kind != .transaction && kind != .stall
            let due = now().timeIntervalSince(s.lastPersist) >= persistInterval
            return (true, rare || due)
        }
        if persist { flush() }
        if !allowed {
            TelemetryCounters.add("telemetry.capped.\(kind.rawValue)")
            if let name { TelemetryCounters.add("telemetry.capped.\(kind.rawValue).\(name)") }
        }
        return allowed
    }

    /// A PostHog event: under its per-name cap AND the all-names cap, both
    /// counted together or not at all. Exempt names always pass and spend
    /// nothing. A refusal records `telemetry.capped.analytics` and
    /// `telemetry.capped.analytics.<name>`.
    public func takeAnalytics(event name: String) -> Bool {
        if Self.exemptAnalyticsEvents.contains(name) { return true }
        let nameKey = "\(Kind.analyticsEvent.rawValue):\(name)"
        let totalKey = Kind.analytics.rawValue
        let (allowed, persist) = state.withLock { s -> (Bool, Bool) in
            roll(&s)
            let perName = Self.hotAnalyticsEvents.contains(name)
                ? s.limits.analyticsHotEvent : s.limits.analyticsEvent
            guard s.counts[nameKey, default: 0] < perName,
                  s.counts[totalKey, default: 0] < s.limits.analytics else { return (false, false) }
            s.counts[nameKey, default: 0] += 1
            s.counts[totalKey, default: 0] += 1
            s.dirty = true
            return (true, now().timeIntervalSince(s.lastPersist) >= persistInterval)
        }
        if persist { flush() }
        if !allowed {
            TelemetryCounters.add("telemetry.capped.analytics")
            TelemetryCounters.add("telemetry.capped.analytics.\(name)")
        }
        return allowed
    }

    /// Metrics: `main_thread.stall_ms` has its own cap, every other name gets
    /// the per-name one; the check-in's are exempt.
    public func takeMetric(_ name: String) -> Bool {
        if Self.isExemptMetric(name) { return true }
        if name == Self.stallMetric { return take(.stall) }
        return take(.metric, name: name)
    }

    /// Root transactions; the check-in is exempt.
    public func takeTransaction(op: String) -> Bool {
        Self.isExemptTransaction(op: op) || take(.transaction)
    }

    /// Today's count for a kind (or metric name), for tests and diagnostics.
    public func used(_ kind: Kind, name: String? = nil) -> Int {
        let key = name.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue
        return state.withLock { s in roll(&s); return s.counts[key, default: 0] }
    }

    /// Writes the counts now. Called on quit and by the throttle.
    public func flush() {
        let snapshot = state.withLock { s -> (Int, [String: Int])? in
            guard s.dirty else { return nil }
            s.dirty = false
            s.lastPersist = now()
            return (s.day, s.counts)
        }
        guard let (day, counts) = snapshot else { return }
        store.set(["day": day, "counts": counts], forKey: Self.defaultsKey)
    }

    /// UTC day number; loads the persisted counts the first time and starts a
    /// fresh set when the UTC day has changed.
    private func roll(_ s: inout State) {
        let today = Int(now().timeIntervalSince1970 / 86_400)
        if !s.loaded {
            s.loaded = true
            if let saved = store.dictionary(forKey: Self.defaultsKey),
               let day = saved["day"] as? Int, day == today,
               let counts = saved["counts"] as? [String: Int] {
                s.day = day
                s.counts = counts
            }
        }
        if s.day != today {
            s.day = today
            s.counts = [:]
            s.dirty = true
        }
    }
}
