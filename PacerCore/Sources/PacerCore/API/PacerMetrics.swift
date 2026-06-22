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

    public init(snapshot s: PacerSnapshotPayload, version: String, build: String) {
        var m: [PacerMetric] = []

        func windowMetrics(_ key: String, _ w: PacerSnapshotPayload.Limits.Window?) {
            guard let w else { return }
            m.append(PacerMetric("pacer_rate_limit_used_ratio", w.usedPercent / 100,
                                 help: "Current rate-limit utilization (0–1).",
                                 labels: [("window", key)]))
            if let s = w.resetsInSeconds {
                m.append(PacerMetric("pacer_rate_limit_reset_seconds", Double(s),
                                     help: "Seconds until the rate-limit window resets.",
                                     labels: [("window", key)]))
            }
            if let end = w.projectedEndPercent {
                m.append(PacerMetric("pacer_rate_limit_projected_end_ratio", end / 100,
                                     help: "Projected utilization at window reset (0–1).",
                                     labels: [("window", key)]))
            }
            m.append(PacerMetric("pacer_rate_limit_will_hit", w.willHitLimit ? 1 : 0,
                                 help: "1 if projected to reach 100% before reset, else 0.",
                                 labels: [("window", key)]))
            if let eta = w.limitEtaInSeconds {
                m.append(PacerMetric("pacer_rate_limit_hit_eta_seconds", Double(eta),
                                     help: "Seconds until the projected 100% crossing.",
                                     labels: [("window", key)]))
            }
        }
        windowMetrics("five_hour", s.limits.fiveHour)
        windowMetrics("seven_day", s.limits.sevenDay)

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
