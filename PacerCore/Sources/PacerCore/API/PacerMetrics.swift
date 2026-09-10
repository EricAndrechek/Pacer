import Foundation

/// One metric series point — a transport-agnostic value the renderers turn
/// into a concrete wire format. Today only `prometheusText()` consumes these;
/// the same list is what a future OTLP exporter would translate into
/// OpenTelemetry `Gauge`/`Sum` data points (one `MetricPoint` → one OTLP
/// `NumberDataPoint` with its labels mapped to attributes). Keeping the metric
/// *model* separate from the metric *encoding* is the whole reason this type
/// exists: add OTLP later without re-deriving any of the math.
public struct PacerMetric: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case gauge
        case counter
    }

    public let name: String
    public let help: String
    public let kind: Kind
    public let labels: [(String, String)]
    public let value: Double

    public init(_ name: String, _ value: Double, kind: Kind = .gauge,
                help: String, labels: [(String, String)] = []) {
        self.name = name
        self.value = value
        self.kind = kind
        self.help = help
        self.labels = labels
    }

    public static func == (lhs: PacerMetric, rhs: PacerMetric) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value && lhs.kind == rhs.kind
            && lhs.help == rhs.help
            && lhs.labels.elementsEqual(rhs.labels, by: ==)
    }
}

/// The full metric set derived from a `PacerSnapshotPayload`, plus the
/// renderers. All names are prefixed `pacer_`; utilizations and pace are
/// expressed as ratios (0–1) per Prometheus convention (multiply by 100 in
/// your dashboard for a percentage). Series whose underlying value is absent
/// (e.g. no engine projection yet) are simply omitted — Prometheus has no
/// "null", and emitting a stand-in would lie.
public struct PacerMetrics: Sendable {
    public let points: [PacerMetric]

    /// One account's rate-limit windows, ready to render as a labelled series.
    ///
    /// `/metrics` passes one of these per account, so `pacer_rate_limit_*`
    /// describes every login rather than only the active one — the gap that
    /// made a second account's headroom unreadable from a scrape. A nil
    /// `accountId` renders the family with no `account` label at all, which is
    /// what an install with no account rows yet (a fresh one, before the first
    /// poll) falls back to.
    ///
    /// **This adds a label to an existing family.** A bare
    /// `pacer_rate_limit_used_ratio{window="five_hour"}` still matches — label
    /// matching is a subset test — but on a multi-account install it now
    /// returns one series per account, so a single-stat panel or an alert rule
    /// that assumed a scalar needs an `account="..."` matcher or an
    /// aggregation. Deliberate: the alternative was a parallel
    /// `pacer_account_rate_limit_*` family, and two names for one measurement
    /// is the thing that makes a metrics endpoint hard to learn.
    public struct AccountLimits: Sendable {
        public let accountId: String?
        public let limits: PacerSnapshotPayload.Limits

        public init(accountId: String?, limits: PacerSnapshotPayload.Limits) {
            self.accountId = accountId
            self.limits = limits
        }
    }

    /// One account's slice of today, ready to render as a series.
    ///
    /// Carries the API row rather than an `Account` so `PacerCore`'s metric
    /// layer stays free of SwiftData — the same reason `PacerMetrics` takes a
    /// `PacerSnapshotPayload` and not a store.
    public struct AccountToday: Sendable {
        public let account: PacerAccountList.Row
        public let models: [PacerDailyUsage.Row]

        public init(account: PacerAccountList.Row, models: [PacerDailyUsage.Row]) {
            self.account = account
            self.models = models
        }

        var costUSD: Double { models.reduce(0) { $0 + $1.costUSD } }
        func tokens(_ kind: (PacerDailyUsage.Row) -> Int) -> Double {
            Double(models.reduce(0) { $0 + kind($1) })
        }
    }

    public init(snapshot s: PacerSnapshotPayload,
                limits accountLimits: [AccountLimits] = [],
                todayModels: [PacerDailyUsage.Row] = [],
                todayAccounts: [AccountToday] = [],
                version: String, build: String) {
        var m: [PacerMetric] = []

        func windowMetrics(_ w: PacerSnapshotPayload.Limits.Window, account: String?) {
            // `account` first, then `window` — the order a series reads in when
            // it is grouped by login. Prometheus itself is order-agnostic.
            var labels: [(String, String)] = []
            if let account { labels.append(("account", account)) }
            labels.append(("window", w.identity))

            m.append(PacerMetric("pacer_rate_limit_used_ratio", w.usedPercent / 100,
                                 help: "Current rate-limit utilization (0–1).",
                                 labels: labels))
            if let s = w.resetsInSeconds {
                m.append(PacerMetric("pacer_rate_limit_reset_seconds", Double(s),
                                     help: "Seconds until the rate-limit window resets.",
                                     labels: labels))
            }
            if let end = w.projectedEndPercent {
                m.append(PacerMetric("pacer_rate_limit_projected_end_ratio", end / 100,
                                     help: "Projected utilization at window reset (0–1).",
                                     labels: labels))
            }
            m.append(PacerMetric("pacer_rate_limit_will_hit", w.willHitLimit ? 1 : 0,
                                 help: "1 if projected to reach 100% before reset, else 0.",
                                 labels: labels))
            if let eta = w.limitEtaInSeconds {
                m.append(PacerMetric("pacer_rate_limit_hit_eta_seconds", Double(eta),
                                     help: "Seconds until the projected 100% crossing.",
                                     labels: labels))
            }
            if let burn = w.burnPercentPerHour {
                m.append(PacerMetric("pacer_rate_limit_burn_percent_per_hour", burn,
                                     help: "Recent burn in percentage points of the window per hour.",
                                     labels: labels))
            }
        }
        // Every window of every account passed in — the fixed 5h/7d blocks and
        // each scoped per-model cap, keyed by its own identity. `window=` used
        // to be one of two hard-coded words, so a "Fable · weekly" cap the
        // dashboard charted was unreadable from a scrape.
        //
        // With nothing passed, the snapshot's own limits render unlabelled,
        // which keeps a caller that knows nothing about accounts on the exact
        // series it had.
        let windowSets = accountLimits.isEmpty
            ? [AccountLimits(accountId: nil, limits: s.limits)]
            : accountLimits
        for set in windowSets {
            for window in set.limits.all { windowMetrics(window, account: set.accountId) }
        }

        let costHelp = "Claude Code spend in USD by period."
        m.append(PacerMetric("pacer_cost_usd", s.cost.todayUSD, help: costHelp, labels: [("period", "today")]))
        m.append(PacerMetric("pacer_cost_usd", s.cost.weekUSD, help: costHelp, labels: [("period", "week")]))
        m.append(PacerMetric("pacer_cost_usd", s.cost.monthUSD, help: costHelp, labels: [("period", "month")]))
        m.append(PacerMetric("pacer_cost_usd", s.cost.allTimeUSD, help: costHelp, labels: [("period", "all_time")]))

        let projHelp = "Projected end-of-period Claude Code spend in USD."
        if let t = s.cost.projectedTodayUSD {
            m.append(PacerMetric("pacer_cost_projected_usd", t, help: projHelp, labels: [("period", "today")]))
        }
        if let mo = s.cost.projectedMonthUSD {
            m.append(PacerMetric("pacer_cost_projected_usd", mo, help: projHelp, labels: [("period", "month")]))
        }

        let tokHelp = "Today's token counts by kind."
        m.append(PacerMetric("pacer_tokens", Double(s.tokens.todayInput), help: tokHelp, labels: [("kind", "input")]))
        m.append(PacerMetric("pacer_tokens", Double(s.tokens.todayOutput), help: tokHelp, labels: [("kind", "output")]))
        m.append(PacerMetric("pacer_tokens", Double(s.tokens.todayCacheRead), help: tokHelp, labels: [("kind", "cache_read")]))

        if let p = s.pace.percentile {
            m.append(PacerMetric("pacer_pace_ratio", p,
                                 help: "Today's projected spend as a percentile of your daily norm (0–1)."))
        }

        m.append(PacerMetric("pacer_overage_usd", s.overageUSD,
                             help: "Current max-plan overage in USD."))

        if let age = s.dataSource.ageSeconds {
            m.append(PacerMetric("pacer_data_age_seconds", Double(age),
                                 help: "Age of the most recent rate-limit sample, in seconds."))
        }
        m.append(PacerMetric("pacer_forecast_fresh", s.dataSource.forecastFresh ? 1 : 0,
                             help: "1 if a fresh engine projection backs the forecast metrics, else 0."))

        // Per-model breakdown for today (omitted when no usage yet).
        let modelCostHelp = "Today's spend per model in USD."
        let modelTokHelp = "Today's token counts per model by kind."
        for row in todayModels {
            m.append(PacerMetric("pacer_model_cost_usd", row.costUSD, help: modelCostHelp,
                                 labels: [("model", row.model)]))
            m.append(PacerMetric("pacer_model_tokens", Double(row.input), help: modelTokHelp,
                                 labels: [("model", row.model), ("kind", "input")]))
            m.append(PacerMetric("pacer_model_tokens", Double(row.output), help: modelTokHelp,
                                 labels: [("model", row.model), ("kind", "output")]))
            m.append(PacerMetric("pacer_model_tokens", Double(row.cacheRead), help: modelTokHelp,
                                 labels: [("model", row.model), ("kind", "cache_read")]))
        }

        // Per-account breakdown for today (omitted on a single-account
        // install, where every series would duplicate the totals above).
        //
        // The series label is the account **id**, not its display label: the
        // label is an email address whenever Pacer has observed one, and a
        // metrics endpoint is the one surface whose output routinely gets
        // shipped to a hosted TSDB. The `_info` series carries a name to join
        // on — see `metricsName` for how far it goes to keep an address out
        // of it.
        if todayAccounts.count > 1 {
            let acctCostHelp = "Today's spend per account in USD."
            let acctTokHelp = "Today's token counts per account by kind."
            for entry in todayAccounts {
                let id = entry.account.id
                m.append(PacerMetric("pacer_account_cost_usd", entry.costUSD, help: acctCostHelp,
                                     labels: [("account", id)]))
                m.append(PacerMetric("pacer_account_tokens", entry.tokens(\.input), help: acctTokHelp,
                                     labels: [("account", id), ("kind", "input")]))
                m.append(PacerMetric("pacer_account_tokens", entry.tokens(\.output), help: acctTokHelp,
                                     labels: [("account", id), ("kind", "output")]))
                m.append(PacerMetric("pacer_account_tokens", entry.tokens(\.cacheRead), help: acctTokHelp,
                                     labels: [("account", id), ("kind", "cache_read")]))
            }
            for entry in todayAccounts {
                m.append(PacerMetric("pacer_account_info", 1,
                                     help: "Account identity; value is always 1. `active` marks the login whose rate limits pacer_rate_limit_* describe.",
                                     labels: [("account", entry.account.id),
                                              ("name", entry.account.metricsName),
                                              ("active", entry.account.isActive ? "true" : "false")]))
            }
        }

        m.append(PacerMetric("pacer_up", 1, help: "Always 1 while the Pacer API is responding."))
        m.append(PacerMetric("pacer_build_info", 1,
                             help: "Pacer build info; value is always 1.",
                             labels: [("version", version), ("build", build)]))

        self.points = m
    }

    /// Render the Prometheus text exposition format (version 0.0.4). HELP/TYPE
    /// are emitted once per metric family, in first-seen order, followed by all
    /// of that family's series.
    public func prometheusText() -> String {
        var order: [String] = []
        var families: [String: (help: String, kind: PacerMetric.Kind, lines: [String])] = [:]
        for p in points {
            if families[p.name] == nil {
                families[p.name] = (p.help, p.kind, [])
                order.append(p.name)
            }
            families[p.name]?.lines.append(p.name + Self.renderLabels(p.labels) + " " + Self.renderValue(p.value))
        }
        var out = ""
        for name in order {
            guard let fam = families[name] else { continue }
            out += "# HELP \(name) \(Self.escapeHelp(fam.help))\n"
            out += "# TYPE \(name) \(fam.kind.rawValue)\n"
            for line in fam.lines { out += line + "\n" }
        }
        return out
    }

    // MARK: - Formatting

    private static func renderLabels(_ labels: [(String, String)]) -> String {
        guard !labels.isEmpty else { return "" }
        let inner = labels
            .map { "\($0.0)=\"\(escapeLabelValue($0.1))\"" }
            .joined(separator: ",")
        return "{\(inner)}"
    }

    /// Plain, locale-independent number. Integral values print without a
    /// decimal point (`7200`, not `7200.0`); fractional values use Swift's
    /// round-trippable `Double` description (no thousands separators, no
    /// exponent for the ranges we emit).
    private static func renderValue(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// HELP text: backslash and newline are the only escapes the format defines.
    private static func escapeHelp(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Label values escape backslash, double-quote, and newline.
    private static func escapeLabelValue(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}
