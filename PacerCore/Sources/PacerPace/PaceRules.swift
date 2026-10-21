import Foundation
import PacerCore

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
        rows.filter { watches(label: $0.label, identity: $0.identity, window: window) }
    }

    static func watches(label: String, identity: String, window: String) -> Bool {
        let sel = window.lowercased()
        if sel.isEmpty || sel == "all" { return true }
        return label.lowercased().contains(sel) || identity.lowercased().contains(sel)
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

    /// The climb a window is making, in points per hour: the measured
    /// half-hour rate, else the engine's smoothed slope. Nil when Pacer
    /// reported neither. The safe limit, a GO's expiry and a resume's headroom
    /// all read it, so they cannot disagree about how fast a window fills.
    static func burnRate(_ row: PaceRow) -> Double? {
        if let recent = row.recentBurn, !recent.isEmpty { return PaceFormat.number(recent) }
        if let burn = row.burn, !burn.isEmpty { return PaceFormat.number(burn) }
        return nil
    }

    /// The safe limit for one window: 100% minus how far usage can climb before
    /// a fresher reading arrives — the recent burn times (the reading's age
    /// plus one worst-case poll), at least 1 point. 98 with no burn measured.
    static func safeLimit(_ row: PaceRow) -> Int {
        guard let b = burnRate(row) else { return 98 }
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

    /// The limit one window trips at (#263): its safe limit less `margin`;
    /// a `--cap` alone replaces the safe limit, as it always has; with both,
    /// whichever is lower. A fixed cap cannot say "the safe limit plus a
    /// buffer": at a heavy burn the safe limit falls below it, and the cap
    /// lets a session run past where the default would have stopped it.
    static func limit(_ row: PaceRow, cap: Cap, margin: Int) -> Double {
        let safe = Double(safeLimit(row) - margin)
        guard let capped = cap.number else { return safe }
        return margin > 0 ? min(capped, safe) : capped
    }

    struct Trip: Equatable, Sendable {
        let label: String
        let percentText: String
        let resetsIn: String?
        /// "cap", "eta", or "room": a `wait` holding after a login switch
        /// because the new login is under its limit but too close to it to
        /// resume onto (#313).
        let why: String
        let hitEta: String?
        /// The level it holds at. For "room", the window's limit less the
        /// headroom a resume needs, so usage falling below it is room.
        let limit: Double
        /// Which window, on which account, so a `wait` can follow this one
        /// window rather than whatever trips next.
        var identity = ""
        var account = ""
        /// The window's safe limit when judged, and whether `limit` came from
        /// it (less any margin) rather than from `--cap`.
        var safe = 0
        var fromSafe = true
        /// For "room": the points below its limit a resume needs.
        var room = 0
    }

    // MARK: - How long a GO holds (#313)

    /// What ends a GO verdict first: one binding window reaching its limit
    /// at its burn, or, with a horizon, its projected fill coming inside it.
    struct Expiry: Equatable, Sendable {
        /// From the reading.
        let seconds: Double
        let label: String
        /// "limit" or "eta".
        let why: String
        let limit: Double
        let burn: Double
    }

    /// The shortest life a GO is given, however near the limit. Pacer's
    /// readings change about once a minute, so re-gating sooner mostly reads
    /// the same one again; the safe limit already allows for a reading that
    /// old plus a whole poll.
    static let minimumGoLife = 60.0

    /// When the soonest binding window stops matching a GO verdict: its
    /// headroom to its limit at its burn, `(limit − used) / burn`, or with a
    /// horizon, its forecast fill minus the horizon. Nil when no window is
    /// climbing, so the verdict's shelf life alone decides.
    ///
    /// A `status` used to take a GO for its whole `--max-age`. At 45%/h, a GO
    /// gated at 88% against a 95% limit is wrong after about 9 minutes, and
    /// lanes kept obeying it for 15: that is how sessions ran into the wall.
    static func goExpiry(_ rows: [PaceRow], cap: Cap, margin: Int = 0, horizon: Int) -> Expiry? {
        var best: Expiry?
        for row in rows {
            let reset = row.resetsIn.map(PaceFormat.number)
            // A reset already due: the next reading is a fresh cycle.
            if let reset, reset <= 0 { continue }
            let limit = limit(row, cap: cap, margin: margin)
            let burn = burnRate(row) ?? 0
            var candidates: [Expiry] = []
            if burn > 0 {
                candidates.append(Expiry(seconds: max(0, limit - row.percent) / burn * 3_600,
                                         label: row.label, why: "limit", limit: limit, burn: burn))
            }
            if horizon > 0, PaceFormat.number(row.willHit) == 1, let eta = row.hitEta.map(PaceFormat.number) {
                candidates.append(Expiry(seconds: max(0, eta - Double(horizon)),
                                         label: row.label, why: "eta", limit: limit, burn: burn))
            }
            // A window that resets first never gets there this cycle, and a
            // GO stays right through a reset.
            for c in candidates where reset.map({ c.seconds <= $0 }) ?? true {
                if best.map({ c.seconds < $0.seconds }) ?? true { best = c }
            }
        }
        return best
    }

    /// How long a GO verdict holds: its expiry, no less than
    /// `minimumGoLife` and no more than `maxAge`. Without an expiry, `maxAge`,
    /// as before.
    static func goLife(_ expiry: Expiry?, maxAge: Int) -> TimeInterval {
        let cap = Double(max(0, maxAge))
        guard let expiry else { return cap }
        return min(cap, max(minimumGoLife, expiry.seconds))
    }

    // MARK: - Room to resume onto after a switch (#313)

    /// The fewest points a resume onto another login needs.
    static let resumeFloor = 5
    /// How much of the burn a resume needs room for.
    static let resumeRunway = 20.0 * 60

    /// What a resume onto a switched-to login needs, and why.
    struct Room: Equatable, Sendable {
        let points: Int
        /// The burn that set `points`; nil when the floor or a fixed
        /// `--resume-headroom` did.
        var burn: Double?
        /// That burn was the old login's.
        var fromOldLogin = false
    }

    /// The headroom a `wait` needs below `row`'s limit to resume onto its
    /// login after a switch: `fixed` points when given (`--resume-headroom`),
    /// else 20 minutes at the higher of the window's burn on the new login
    /// and on the old one (`oldBurn`), at least 5 points, in whole points.
    ///
    /// The old login's burn counts because the workload moves with the
    /// sessions: the ones waiting were burning the old login, and they all
    /// resume onto the new one. An idle new login reports about 0%/h, which
    /// judged alone let every waiting session resume onto a login at 97%.
    static func resumeHeadroom(_ row: PaceRow, fixed: Int?, oldBurn: Double?) -> Room {
        if let fixed { return Room(points: fixed) }
        let new = max(0, burnRate(row) ?? 0), old = max(0, oldBurn ?? 0)
        let burn = max(new, old)
        let needed = Int((burn * resumeRunway / 3_600).rounded(.up))
        guard needed > resumeFloor else { return Room(points: resumeFloor) }
        return Room(points: needed, burn: burn, fromOldLogin: old > new)
    }

    /// What a paused `wait` is waiting out (#267): the window that tripped,
    /// on which account, when its cycle resets, and the limit it tripped at.
    /// Held for the whole wait because the safe limit is not: it rises as
    /// paused sessions cut the burn, so re-judging every poll let the 97%
    /// that paused at a safe limit of 97 "reset" a few polls later at 98,
    /// with nothing reset.
    struct Anchor: Equatable, Sendable {
        var trip: Trip
        let resetsAt: Date?
    }

    /// Why an anchored window no longer holds a wait.
    enum Release: Equatable, Sendable {
        /// Its cycle rolled over.
        case reset
        /// Its usage fell below the limit it paused at.
        case drop
        /// A forecast pause (`--eta`): it is no longer projected to fill.
        case forecast
    }

    /// How long a window's cycle is, to tell "the next cycle" from jitter in
    /// one cycle's reset instant. Unknown kinds take the shortest window
    /// there is: a later cycle is at least that far off, and one cycle's
    /// reset never drifts by half of it.
    static func cycleLength(identity: String) -> TimeInterval {
        if let fixed = PaceMath.windowDuration(for: identity) { return fixed }
        let kind = identity.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if kind.contains("week") || kind.contains("seven") { return 7 * 86_400 }
        if kind.contains("day") || kind.contains("daily") { return 86_400 }
        return 5 * 3_600
    }

    /// Whether the anchored window has cleared in `rows`: its reset is due
    /// or past, a reading belongs to a later cycle (never `resetsAt ==`: the
    /// instant jitters, AGENTS.md rule 9), or its usage fell below the
    /// anchored limit (for a forecast pause, under it and no longer projected
    /// within `horizon`). Nil while it holds. A window missing from the
    /// reading holds until its reset: absent is not empty.
    static func release(_ anchor: Anchor, rows: [PaceRow], now: Date, horizon: Int) -> Release? {
        if let resetsAt = anchor.resetsAt, now >= resetsAt { return .reset }
        guard let row = rows.first(where: {
            $0.identity == anchor.trip.identity && $0.account == anchor.trip.account
        }) else { return nil }
        if let secs = row.resetsIn.map(PaceFormat.number) {
            // A reset already due: the reading describes the window that ended.
            if secs <= 0 { return .reset }
            if let resetsAt = anchor.resetsAt,
               !RateLimitCycle.contains(sampleReset: now.addingTimeInterval(secs), resets: resetsAt,
                                        duration: cycleLength(identity: row.identity)) {
                return .reset
            }
        }
        guard row.percent < anchor.trip.limit else { return nil }
        // A "room" hold's limit is already the level with room enough.
        guard anchor.trip.why == "eta" else { return .drop }
        let projected = horizon > 0 && PaceFormat.number(row.willHit) == 1
            && row.hitEta.map { PaceFormat.number($0) <= Double(horizon) } == true
        return projected ? nil : .forecast
    }

    /// The binding window that is at or over its limit — or, with a horizon,
    /// projected to fill inside it — and resets soonest. Nil means headroom.
    static func evaluate(_ rows: [PaceRow], cap: Cap, margin: Int = 0, horizon: Int) -> Trip? {
        var best: Trip?
        var bestSeconds = 0.0
        for row in rows {
            let safe = safeLimit(row)
            let limit = limit(row, cap: cap, margin: margin)
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
                            why: why, hitEta: row.hitEta, limit: limit,
                            identity: row.identity, account: row.account, safe: safe,
                            fromSafe: cap.number.map { limit < $0 } ?? true)
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

    /// An instant as UTC `22:41Z`: when a GO verdict runs out (#313). UTC,
    /// like the state file's stamps, so a lane and its orchestrator on
    /// different clocks read the same time. Unix time has no leap seconds or
    /// offsets, so the time of day is arithmetic.
    static func utcClock(_ date: Date) -> String {
        let day = 86_400
        let second = (Int(floor(date.timeIntervalSince1970)) % day + day) % day
        return String(format: "%02d:%02dZ", second / 3_600, second % 3_600 / 60)
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
