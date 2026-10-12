import Foundation

/// One rate-limit window of one account, as `pace.sh` held it in its row
/// format: the parsed percentage, and the other fields as Pacer wrote them
/// (nil where `pace.sh` wrote `null`).
struct PaceRow: Equatable, Sendable {
    let account: String
    let identity: String
    let label: String
    /// The model a per-model cap names; empty for an account-wide window.
    let model: String
    let percent: Double
    let resetsIn: String?
    let hitEta: String?
    let burn: String?
    /// `1` when the forecast says this window fills before it resets.
    let willHit: String
    let recentBurn: String?
    let sampleAge: String?

    /// The percentage as awk printed it: `95`, `41.5`, `33.3333`.
    var percentText: String { PaceFormat.awkNumber(percent) }
    var resetSeconds: Int? { resetsIn.flatMap(PaceFormat.integer) }
}

/// The rules `pace.sh` applied to those rows, one function each, so the
/// report's marker, the gate's verdict and `json`'s `binds` cannot disagree.
enum PaceRules {

    /// `five_hour` → `5h`; `weekly_scoped|Fable|` → `Fable`; a surface, or the
    /// kind, when no model is named.
    static func label(forIdentity id: String) -> String {
        if id == "five_hour" { return "5h" }
        if id == "seven_day" { return "7d" }
        let model = model(forIdentity: id)
        if !model.isEmpty { return model }
        let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, !parts[2].isEmpty { return parts[2] }
        return parts.first ?? id
    }

    static func model(forIdentity id: String) -> String {
        if id == "five_hour" || id == "seven_day" { return "" }
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    /// `--window`: a case-insensitive substring of the label or the identity.
    static func selected(_ rows: [PaceRow], window: String) -> [PaceRow] {
        let sel = window.lowercased()
        if sel.isEmpty || sel == "all" { return rows }
        return rows.filter { $0.label.lowercased().contains(sel) || $0.identity.lowercased().contains(sel) }
    }

    /// Stands for "which model I am is not knowable here". Only windows that
    /// name no model bind it.
    static let ambiguousModel = "__ambiguous__"

    static func normalized(_ v: String) -> String {
        String(v.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }.map(Character.init))
    }

    /// Whether a window naming `windowModel` constrains work run as `wanted`.
    /// Account-wide windows bind everything; names match loosely, because the
    /// server says "Fable" where a caller says `claude-fable-5-1`.
    static func binds(windowModel: String, wanted: String) -> Bool {
        let m = normalized(windowModel)
        if wanted == ambiguousModel { return m.isEmpty }
        let want = normalized(wanted)
        if want.isEmpty || want == "all" || m.isEmpty { return true }
        return m.contains(want) || want.contains(m)
    }

    static func binding(_ rows: [PaceRow], window: String, model: String) -> [PaceRow] {
        selected(rows, window: window).filter { binds(windowModel: $0.model, wanted: model) }
    }

    /// The longest a reading can go unrefreshed: Pacer polls each token at most
    /// every 5 minutes.
    static let pollWorst = 300.0

    /// The safe limit for one window: 100% minus how far usage can climb before
    /// a fresher reading arrives — the recent burn times (the reading's age
    /// plus one worst-case poll), at least 1 point. 98 with no burn measured.
    static func safeLimit(_ row: PaceRow) -> Int {
        let b: Double
        if let recent = row.recentBurn, !recent.isEmpty { b = PaceFormat.number(recent) }
        else if let burn = row.burn, !burn.isEmpty { b = PaceFormat.number(burn) }
        else { return 98 }
        let age = row.sampleAge.flatMap { $0.isEmpty ? nil : PaceFormat.number($0) } ?? pollWorst
        var m = max(0, b) * (age + pollWorst) / 3600
        if m < 1 { m = 1 }
        let points = m == m.rounded(.towardZero) ? Int(m) : Int(m) + 1
        return 100 - points
    }

    enum Cap: Equatable, Sendable {
        case safe
        /// As typed, because messages and the state file echo it verbatim.
        case value(String)

        var number: Double? {
            if case .value(let text) = self { return PaceFormat.number(text) }
            return nil
        }
    }

    struct Trip: Equatable, Sendable {
        let label: String
        let percentText: String
        let resetsIn: String?
        let why: String          // "cap" or "eta"
        let hitEta: String?
        let limit: Double
    }

    /// The binding window that is at or over its limit — or, with a horizon,
    /// projected to fill inside it — and resets soonest. Nil means headroom.
    static func evaluate(_ rows: [PaceRow], cap: Cap, horizon: Int) -> Trip? {
        var best: Trip?
        var bestSeconds = 0.0
        for row in rows {
            let limit = cap.number ?? Double(safeLimit(row))
            // A reset already due describes the window that just ended: Pacer
            // polls every few minutes, so for a while its last reading still
            // says "85%, resets in 0m".
            if let secs = row.resetsIn, PaceFormat.number(secs) <= 0 { continue }
            let why: String
            if row.percent >= limit {
                why = "cap"
            } else if horizon > 0, PaceFormat.number(row.willHit) == 1,
                      let eta = row.hitEta, PaceFormat.number(eta) <= Double(horizon) {
                why = "eta"
            } else {
                continue
            }
            let s = row.resetsIn.map(PaceFormat.number) ?? 9_999_999
            if best == nil || s < bestSeconds {
                best = Trip(label: row.label, percentText: row.percentText, resetsIn: row.resetsIn,
                            why: why, hitEta: row.hitEta, limit: limit)
                bestSeconds = s
            }
        }
        return best
    }
}

/// `pace.sh`'s number and time formatting, reproduced exactly: its output is
/// read by people and by other scripts, and a rounding change is a change of
/// answer.
enum PaceFormat {

    /// awk's numeric-to-string rule: integral values as integers, others with
    /// `%.6g`.
    static func awkNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.6g", value)
    }

    /// awk's `x + 0`: the leading number in a string, 0 when there is none.
    static func number(_ text: String) -> Double {
        if let d = Double(text) { return d }
        let scanner = Scanner(string: text)
        return scanner.scanDouble() ?? 0
    }

    /// Bash arithmetic on a field: whole seconds.
    static func integer(_ text: String) -> Int? {
        if let i = Int(text) { return i }
        return Double(text).map { Int($0) }
    }

    /// Seconds → `3d 9h` / `1h 12m` / `7m`; `?` for no value.
    static func human(_ seconds: String?) -> String {
        guard let seconds, seconds != "null", let s = integer(seconds) else { return "?" }
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func human(_ seconds: Int) -> String { human(String(seconds)) }

    nonisolated(unsafe) private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE h:mm a"
        return f
    }()

    /// Seconds from now → local `Sun 5:00 PM`.
    static func clock(_ seconds: String?, now: Date) -> String {
        guard let seconds, seconds != "null", let s = integer(seconds) else { return "?" }
        let whole = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + Double(s))
        return clockFormatter.string(from: whole)
    }

    /// `61.99999` → `62`; `4.5` → `4.5`.
    static func percent(_ text: String?) -> String {
        guard let text, !text.isEmpty, text != "null" else { return "?" }
        var r = String(format: "%.1f", number(text))
        if r.hasSuffix(".0") { r.removeLast(2) }
        return r
    }

    /// `%+.0f`.
    static func signed(_ text: String) -> String { String(format: "%+.0f", number(text)) }

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `date -u +%Y-%m-%dT%H:%M:%SZ`.
    static func utcStamp(_ date: Date) -> String { isoFormatter.string(from: date) }
}
