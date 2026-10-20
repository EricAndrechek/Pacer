import Foundation

/// What a `pace` run can touch, injectable so the commands can be tested
/// in-process: output, the clock, sleeping, the network, and `git`.
public struct PaceIO: @unchecked Sendable {
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var now: () -> Date
    public var sleep: (TimeInterval) -> Void
    /// One GET. Nil for a transport failure (nothing listening, a timeout, a
    /// missing `file://` path); a nil status for a non-HTTP URL, which
    /// `pace.sh` saw as curl's `000` and treated as a success.
    public var get: (URLRequest) -> PaceResponse?
    /// The branch checked out at a path, for `sessions`.
    public var gitBranch: (String) -> String?
    /// A short pause that is not a wait for Pacer: a `status` that lost the
    /// race to refresh a verdict naps while the winner writes it (#266).
    /// Separate from `sleep`, which opens Pacer's stream on first use.
    public var nap: (TimeInterval) -> Void

    public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                now: @escaping () -> Date, sleep: @escaping (TimeInterval) -> Void,
                get: @escaping (URLRequest) -> PaceResponse?,
                gitBranch: @escaping (String) -> String?,
                nap: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.out = out
        self.err = err
        self.now = now
        self.sleep = sleep
        self.get = get
        self.gitBranch = gitBranch
        self.nap = nap
    }

    /// The real thing: stdout, stderr, the wall clock, URLSession and git.
    public static var standard: PaceIO { live(offline: nil) }

    /// The real thing, and when nothing answers on Pacer's port, `offline`
    /// answers from the store instead (#194). Only a transport failure falls
    /// back: a 401, a 503 or a 404 is Pacer's answer, not its absence.
    ///
    /// A sleep (only `wait` and the retry backoff sleep) returns early when
    /// Pacer's stream pushes an event (#256); see `PaceStream`.
    public static func live(offline: PaceOffline?,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> PaceIO {
        var base = environment["PACER_API"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:7223"
        if base.hasSuffix("/") { base.removeLast() }
        let stream = PaceStream(apiBase: base,
                                token: environment["PACE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 })
        return PaceIO(
            out: { FileHandle.standardOutput.write(Data($0.utf8)) },
            err: { FileHandle.standardError.write(Data($0.utf8)) },
            now: Date.init,
            sleep: { seconds in
                if let stream { stream.sleep(seconds) } else { Thread.sleep(forTimeInterval: seconds) }
            },
            get: { request in PaceHTTP.get(request) ?? offline?.answer(request) },
            gitBranch: PaceHTTP.gitBranch)
    }
}

public struct PaceResponse: Sendable {
    public let status: Int?
    public let body: String
    public init(status: Int?, body: String) {
        self.status = status
        self.body = body
    }
}

/// The `pace` commands of the `pacer` command line (#194): `accounts`,
/// `sessions`, `report`, `json`, `gate`, `status` and `wait`.
///
/// A port of the bash `pace.sh`, rule for rule, which it replaced: the skill
/// now runs `pacer`, and the script is gone. Its exit codes, state files, flags, environment and
/// output are a contract that CLAUDE.md imports, prompts and `pace-guard.sh`
/// depend on, so this keeps every one of them; `PaceParityTests` runs the
/// frozen script (`Tests/PacerPaceTests/Oracle`) and this against the same
/// fixtures and compares. The deliberate differences are listed there.
public enum Pace {

    /// Run one command line (`["gate", "--cap", "85"]`) and return its exit
    /// status.
    public static func run(_ arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           io: PaceIO = .standard) -> Int32 {
        let run = PaceRun(environment: environment, io: io)
        do {
            try run.main(arguments)
            return 0
        } catch let exit as PaceExit {
            return exit.code
        } catch {
            io.err("pace: \(error)\n")
            return 1
        }
    }

    /// For the "unknown subcommand" message.
    static let subcommands = ["report", "json", "accounts", "sessions", "gate", "status", "wait", "safecap"]

    /// `pacer --help`.
    public static let help = """
    pacer — report Claude usage from Pacer and gate heavy work against
    every rate-limit window, so hitting a limit costs a resumable pause rather
    than a lost run. Reads Pacer's local API when it is on, its data when not.

    Design: ONE poller, MANY cheap readers.
      - An orchestrator runs `gate` once per fan-out wave (a fresh read of
        Pacer), which writes a shared state file.
      - The subagents only ever run `status` — a file read. When the verdict
        has gone stale, one of them re-gates it for all of them, so a hundred
        cost Pacer one read per staleness period.
      - On a trip, `wait` blocks (background-friendly) until the window resets,
        then exits so the launcher is re-invoked to resume.

    Subcommands:
      accounts               every account: plan, live sessions, windows
      sessions               where the live sessions are, with branches
      report                 human table of every window
      json                   machine JSON of the same
      gate  [--cap N]        read Pacer + write state file; 0=go 10=paused
                             2=no Pacer 4=misconfigured
      safecap                the limit gate applies to each binding window,
                             one per line (label, percent), for scripts
      status                 read the state file; 0=go 10=paused 3=unknown or
                             stale. A stale, expired or missing verdict is
                             re-gated first, by one reader for all of them
                             (--no-refresh: never ask Pacer)
      wait  [--cap N]        block until the tripping window resets; 0=resume
                             20=beyond --max-wait (checkpoint & stop) 2=no Pacer

    Flags:
      --model NAME|auto|all  which per-model caps bind (account-wide windows
                             always do); default auto where
                             CLAUDE_CODE_SESSION_ID is set, else all
      --cap N                pause at N% (default: each window's safe limit,
                             see `safecap`)
      --margin N             stop N points below each window's safe limit;
                             with --cap, the lower of the two wins
      --eta DURATION         also pause when a window is projected to fill
                             within DURATION (90m, 2h); default off
      --window SEL           a label or identity substring (5h, 7d, fable);
                             default all
      --account ID|all       whose windows; default this session's login
      --interval S           how often `wait` looks; default 15, floor 5
      --max-wait S           longest reset `wait` sleeps for; default 21600
      --max-age S            how old a verdict may be before `status` calls
                             it stale; default 900
      --retries N            reads of Pacer before giving up; default 3
      --state FILE           the state file; default state-session-<id>.json
                             in ~/.claude/pace for a Claude Code session,
                             state-<PACE_RUN>.json for a named run, else
                             state.json

    Env: PACER_API (default http://127.0.0.1:7223), PACE_TOKEN (bearer, optional),
      PACE_SESSION_API (override just the session lookup's base URL),
      PACE_MODEL, PACE_MARGIN, PACE_ACCOUNT, PACE_STATE, PACE_RUN (names a per-run state file, so two
      orchestrations on one machine do not overwrite each other's verdict)

    """
}

struct PaceExit: Error {
    let code: Int32
}

/// One run's state: the script's globals, kept as they were so the port can be
/// read against it line by line.
final class PaceRun {
    private let env: [String: String]
    /// `var` so a refreshing `status` can run the gate with its stdout muted.
    private var io: PaceIO

    private var apiBase: String
    private var api: String { apiBase + "/metrics" }
    private var statePath: String
    /// The state file is this session's default one (#265), which `gate`
    /// may prune old siblings of; not one a caller named.
    private var stateIsSessionDefault = false
    private var account: String
    private var cap: PaceRules.Cap = .safe
    /// Points below each window's safe limit to stop at (#263).
    private var margin = 0
    /// Which of the gating settings were given (flag, or PACE_MODEL). A
    /// `wait` takes the rest from the gate that paused (#258).
    private var given: Set<String> = []
    private var interval = 300
    private var intervalSet = false
    private var window = "all"
    private var maxWait = 21_600
    private var maxAge = 900
    /// `status --no-refresh`: the pure file read, never asking Pacer (#266).
    private var noRefresh = false
    private var model: String
    /// The model was `auto` before it was resolved, so a verdict records
    /// that and a later `wait` or refresh asks again rather than reusing
    /// what this session ran at gate time.
    private var modelAuto = false
    private var eta = 0
    private var retries: Int
    private var token: String?

    private var scope: [URLQueryItem] = []
    private var allAccounts = 0
    private var want: String

    private var sessionModel = ""
    private var sessionModels: [String] = []
    private var sessionAccount = ""
    private var sessionAccountSince = ""
    private var sessionLookedUp = false
    private var autoNote = ""

    private var rows: [PaceRow] = []
    private var fetchReason: String?
    private var httpCode = ""
    private var httpBody = ""

    init(environment: [String: String], io: PaceIO) {
        env = environment
        self.io = io
        var base = environment["PACER_API"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:7223"
        if base.hasSuffix("/") { base.removeLast() }
        apiBase = base
        let run = environment["PACE_RUN"].flatMap { $0.isEmpty ? nil : $0 }
        let dir = "\(environment["HOME"] ?? NSHomeDirectory())/.claude/pace"
        if let path = environment["PACE_STATE"].flatMap({ $0.isEmpty ? nil : $0 }) {
            statePath = path
        } else if let run {
            statePath = "\(dir)/state-\(run).json"
        } else if let session = PaceStateFile.sessionTag(environment["CLAUDE_CODE_SESSION_ID"]) {
            // One verdict per session by default (#265). A shared file let a
            // test `gate --cap 50` in one session pause every session on the
            // machine. Subagents run under their parent's session id, so a
            // session's own lanes still share one verdict.
            statePath = "\(dir)/state-session-\(session).json"
            stateIsSessionDefault = true
        } else {
            statePath = "\(dir)/state.json"
        }
        account = environment["PACE_ACCOUNT"] ?? ""
        model = environment["PACE_MODEL"] ?? ""
        if !model.isEmpty { given.insert("model") }
        retries = environment["PACE_RETRIES"].flatMap { Int($0) } ?? 3
        token = environment["PACE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        want = environment["PACE_ACCOUNT"] ?? ""
    }

    // MARK: - Entry

    func main(_ arguments: [String]) throws {
        var args = arguments[...]
        let sub = args.popFirst() ?? "report"
        while let flag = args.popFirst() {
            func value() throws -> String {
                guard let v = args.popFirst() else { try die("\(flag) needs a value") }
                return v
            }
            switch flag {
            case "--cap":      let v = try value(); cap = v == "safe" ? .safe : .value(v); given.insert("cap")
            case "--margin":   margin = try points(try value(), flag); given.insert("margin")
            case "--interval": interval = try integer(try value(), flag); intervalSet = true
            case "--window":   window = try value(); given.insert("window")
            case "--model":    model = try value(); given.insert("model")
            case "--eta":      eta = try duration(try value()); given.insert("eta")
            case "--account":  account = try value()
            case "--max-wait": maxWait = try integer(try value(), flag)
            case "--max-age":  maxAge = try integer(try value(), flag)
            case "--retries":  retries = try integer(try value(), flag)
            case "--state":    statePath = try value(); stateIsSessionDefault = false
            case "--no-refresh": noRefresh = true
            case "-h", "--help":
                io.out(Pace.help)
                throw PaceExit(code: 0)
            default: try die("unknown flag: \(flag)")
            }
        }
        if interval < 5 { interval = 5 }
        if !given.contains("margin"), let raw = env["PACE_MARGIN"], !raw.isEmpty {
            margin = try points(raw, "PACE_MARGIN")
            given.insert("margin")
        }

        // `status` is a file read: it judges the verdict it finds, with no
        // model default (#264), and asks Pacer nothing unless it has to
        // re-gate (#266). It used to look the session up on every call, which
        // with the API off opened the store, once per reader.
        if sub != "status" {
            defaultModel()
            prepare()
        }

        switch sub {
        case "accounts": try cmdAccounts()
        case "sessions": try cmdSessions()
        case "report":   try cmdReport()
        case "json":     try cmdJSON()
        case "gate":     try cmdGate()
        case "status":   try cmdStatus()
        case "safecap":  try cmdSafecap()
        case "wait":     try cmdWait()
        default: try die("unknown subcommand '\(sub)' (\(Pace.subcommands.joined(separator: "|")))")
        }
    }

    /// A caller that names no model, in a session Pacer can identify, is
    /// asking about that session (#264). "Every window binds" paused Opus and
    /// Sonnet work on a Fable cap that never constrained it: 73 false PAUSEs
    /// in a fortnight on one machine. `auto` binds what certainly applies,
    /// and still falls back to every window when Pacer has not seen the
    /// session. `--model all` asks for every window explicitly.
    private func defaultModel() {
        if model.isEmpty, !given.contains("model"),
           let id = env["CLAUDE_CODE_SESSION_ID"], !id.isEmpty {
            model = "auto"
        }
    }

    /// Who is asking, before reading Pacer for them. Which account you are is
    /// not a function of which model you run: an orchestrator passing
    /// `--model opus` once got no session lookup, fell back to the idle
    /// active login, and reported GO at 0% while its own account sat at 65%.
    private func prepare() {
        if account.isEmpty || account == "all" { _ = resolveSession() }
        resolveAutoModel()
        setScope()
    }

    private func die(_ message: String) throws -> Never {
        io.err("pace: \(message)\n")
        throw PaceExit(code: 1)
    }

    private func integer(_ text: String, _ flag: String) throws -> Int {
        guard let v = Int(text) else { try die("\(flag) takes a whole number, not '\(text)'") }
        return v
    }

    /// A margin: whole points, none negative. A margin that raised the limit
    /// above the safe one would be a cap, and `--cap` already says that.
    private func points(_ text: String, _ name: String) throws -> Int {
        guard let v = Int(text), v >= 0 else { try die("\(name) takes a whole number of points, 0 or more, not '\(text)'") }
        return v
    }

    /// "90m" / "2h" / "5400" → seconds. Anything unparseable is a typo worth
    /// stopping for, not a zero to silently ignore.
    private func duration(_ text: String) throws -> Int {
        if text.isEmpty || text == "0" { return 0 }
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3_600]
        if let unit = text.last, let scale = units[unit], let n = Int(text.dropLast()) { return n * scale }
        if let n = Int(text) { return n }
        try die("cannot read duration '\(text)' (try 90m, 2h, or plain seconds)")
    }

    // MARK: - Reading Pacer

    private func request(_ url: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard var components = URLComponents(string: url) else { return nil }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        guard let resolved = components.url else { return nil }
        var request = URLRequest(url: resolved, timeoutInterval: 5)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func get(_ url: String, query: [URLQueryItem] = []) -> PaceResponse? {
        guard let request = request(url, query: query) else { return nil }
        return io.get(request)
    }

    /// Ask Pacer about *this* session: the model it runs and the account it
    /// bills, keyed by the id Claude Code exports into every command.
    @discardableResult
    private func resolveSession() -> Bool {
        if sessionLookedUp { return false }
        sessionLookedUp = true
        guard let id = env["CLAUDE_CODE_SESSION_ID"], !id.isEmpty else { return false }
        let base = env["PACE_SESSION_API"].flatMap { $0.isEmpty ? nil : $0 } ?? apiBase
        guard let response = get(base + "/v1/session", query: [URLQueryItem(name: "id", value: id)]),
              response.body.contains("\"sessionId\"") else { return false }
        let body = response.body
        sessionModel = Self.quotedField(body, key: "model") ?? ""
        // The login the session's next turn bills to, where Pacer says. The
        // account of its last stored turn stays on the old login after a
        // `/login` until the session writes another turn (#184).
        sessionAccount = Self.quotedField(body, key: "currentAccountId") ?? ""
        if sessionAccount.isEmpty { sessionAccount = Self.quotedField(body, key: "accountId") ?? "" }
        sessionAccountSince = Self.quotedField(body, key: "currentAccountSince") ?? ""
        sessionModels = Self.models(in: body)
        return !sessionModel.isEmpty || !sessionAccount.isEmpty
    }

    /// The value on the first line naming `"key"`: the field between its third
    /// and fourth quote, empty for a non-string. Line-oriented, as `pace.sh`
    /// read it, because Pacer's encoder prints one key per line.
    static func quotedField(_ body: String, key: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false)
        where line.contains("\"\(key)\"") {
            let f = line.split(separator: "\"", omittingEmptySubsequences: false)
            return f.count >= 4 ? String(f[3]) : ""
        }
        return nil
    }

    /// Every string in the `"models"` array.
    static func models(in body: String) -> [String] {
        let lines = body.replacingOccurrences(of: ",", with: "\n").split(separator: "\n")
        var inside = false
        var out: [String] = []
        for line in lines {
            if !inside, line.contains("\"models\"") { inside = true }
            guard inside else { continue }
            var rest = Substring(line)
            while let open = rest.firstIndex(of: "\"") {
                let after = rest.index(after: open)
                guard let close = rest[after...].firstIndex(of: "\"") else { break }
                let value = String(rest[after..<close])
                if value != "models" { out.append(value) }
                rest = rest[rest.index(after: close)...]
            }
            if line.contains("]") { break }
        }
        return out
    }

    /// `--model auto` means "whatever this session is running". The note
    /// always reads `model auto: …`, so a verdict reached by default says so.
    private func resolveAutoModel() {
        guard model == "auto" else { return }
        modelAuto = true
        if sessionModels.count > 1 {
            // A parent and its subagents at once, and nothing here says which
            // one is asking: bind what certainly applies and nothing else.
            model = PaceRules.ambiguousModel
            autoNote = "model auto: ambiguous (\(sessionModels.joined(separator: ","))) — account-wide windows only; pass --model to gate on yours"
        } else if !sessionModel.isEmpty {
            model = sessionModel
            autoNote = "model auto: detected \(model)"
        } else {
            model = ""
            autoNote = "model auto: unknown — every window binds"
        }
    }

    /// Which login to ask about, and which to keep when the answer arrives.
    /// They have to agree: after a switch, asking for the session's account
    /// while keeping the *active* one filtered every row out (#184).
    private func setScope() {
        scope = []
        want = env["PACE_ACCOUNT"] ?? ""
        if !account.isEmpty, account != "all" {
            scope = [URLQueryItem(name: "account", value: account)]
            want = account
        } else if !sessionAccount.isEmpty {
            scope = [URLQueryItem(name: "account", value: sessionAccount)]
            want = sessionAccount
        } else if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            // Only Pacer can turn a config directory into an id, so the
            // response is taken as already narrowed.
            scope = [URLQueryItem(name: "config_dir", value: dir)]
            want = "all"
        }
    }

    /// Look the session's account up again: a `wait` that resolved once kept
    /// asking about the login it started on (#184). An explicit `--account`
    /// stays.
    private func refreshScope() {
        if account.isEmpty || account == "all" {
            sessionLookedUp = false
            sessionAccount = ""
            resolveSession()
        }
        setScope()
    }

    /// Fill `rows`, or say why not in `fetchReason`:
    /// `off` (nothing answered), `auth` (401/403), `http` (anything else
    /// unhappy) or `empty` (no windows). Retried first: Pacer restarts itself
    /// for updates, and "nothing listening" during one is not "no limits".
    private func fetchRows() -> Bool {
        fetchReason = "off"
        var attempt = 1
        while attempt <= retries {
            if let response = get(api, query: scope) {
                switch response.status {
                case 401, 403:
                    fetchReason = "auth"
                    return false
                case nil, 200:
                    break
                case let code?:
                    fetchReason = "http"
                    httpCode = String(code)
                    httpBody = response.body.split(separator: "\n", omittingEmptySubsequences: false)
                        .first.map(String.init) ?? ""
                    return false
                }
                if !response.body.isEmpty {
                    let points = PaceMetricsText.parse(response.body)
                    // Counted before narrowing, or the caveat about several
                    // signed-in accounts could never fire.
                    allAccounts = points.filter { $0.name == "pacer_account_info" }.count
                    rows = Self.rows(from: points, want: want)
                    if !rows.isEmpty {
                        fetchReason = nil
                        return true
                    }
                    fetchReason = "empty"
                    return false
                }
            }
            if attempt < retries { io.sleep(TimeInterval(attempt)) }
            attempt += 1
        }
        return false
    }

    /// One row per (account, window) with a reading, narrowed to one login:
    /// `want` if given (a prefix: `accounts` prints ids cut to 8, #184), else
    /// the login `pacer_account_info` marks active, else the only account.
    static func rows(from points: [PaceMetricPoint], want: String) -> [PaceRow] {
        struct Slot: Hashable { let account: String; let window: String }
        var order: [Slot] = []
        var seen = Set<Slot>()
        var accounts: [String] = []
        var active = ""
        var pct: [Slot: Double] = [:]
        var fields: [String: [Slot: String]] = [:]
        func slot(_ p: PaceMetricPoint) -> Slot {
            let s = Slot(account: p.label("account"), window: p.label("window"))
            if seen.insert(s).inserted { order.append(s) }
            if !accounts.contains(s.account) { accounts.append(s.account) }
            return s
        }
        let kept: Set<String> = [
            "pacer_rate_limit_reset_seconds", "pacer_rate_limit_hit_eta_seconds",
            "pacer_rate_limit_will_hit", "pacer_rate_limit_burn_percent_per_hour",
            "pacer_rate_limit_recent_burn_percent_per_hour", "pacer_rate_limit_sample_age_seconds",
        ]
        for p in points {
            if p.name == "pacer_account_info" {
                if p.label("active") == "true" { active = p.label("account") }
            } else if p.name == "pacer_rate_limit_used_ratio" {
                pct[slot(p)] = p.value * 100
            } else if kept.contains(p.name) {
                fields[p.name, default: [:]][slot(p)] = p.raw
            }
        }
        var wanted = want
        if wanted.isEmpty { wanted = !active.isEmpty ? active : (accounts.count == 1 ? accounts[0] : "") }
        if wanted == "all" { wanted = "" }
        return order.compactMap { s in
            guard wanted.isEmpty || s.account.hasPrefix(wanted), let percent = pct[s] else { return nil }
            func f(_ name: String) -> String? { fields[name]?[s] }
            return PaceRow(
                account: s.account, identity: s.window,
                label: PaceRules.label(forIdentity: s.window),
                model: PaceRules.model(forIdentity: s.window),
                percent: percent,
                resetsIn: f("pacer_rate_limit_reset_seconds"),
                hitEta: f("pacer_rate_limit_hit_eta_seconds"),
                burn: f("pacer_rate_limit_burn_percent_per_hour"),
                willHit: f("pacer_rate_limit_will_hit") ?? "0",
                recentBurn: f("pacer_rate_limit_recent_burn_percent_per_hour"),
                sampleAge: f("pacer_rate_limit_sample_age_seconds"))
        }
    }

    // MARK: - Shared pieces

    private var selectedRows: [PaceRow] { PaceRules.selected(rows, window: window) }
    private var bindingRows: [PaceRow] { PaceRules.binding(rows, window: window, model: model) }

    /// A `--window` that matches nothing is a typo, not "no limits".
    private func requireSelection() throws {
        if window.isEmpty || window == "all" { return }
        if !selectedRows.isEmpty { return }
        io.err("pace: --window '\(window)' matches no window. Available: \(rows.map(\.label).joined(separator: ", "))\n")
        throw PaceExit(code: 1)
    }

    private func autoNoteText() -> String { autoNote.isEmpty ? "" : " (\(autoNote))" }

    /// Whose numbers these are, when that had to be inferred.
    private func scopeCaveat() -> String {
        if !want.isEmpty, want != "all" { return "" }
        if allAccounts <= 1 { return "" }
        return " (\(allAccounts) accounts signed in and this session could not be identified — these are the active login's numbers, which may not be the ones billing you; pass --account, or run where CLAUDE_CODE_SESSION_ID is set)"
    }

    private func tripReason(_ trip: PaceRules.Trip) -> String {
        if trip.why == "eta" {
            return "\(trip.label) at \(PaceFormat.percent(trip.percentText))% is projected to fill in \(PaceFormat.human(trip.hitEta)) (horizon \(PaceFormat.human(eta)))"
        }
        let at = "\(trip.label) at \(PaceFormat.percent(trip.percentText))% >= "
        if case .value(let text) = cap, !trip.fromSafe { return at + "cap \(text)%" }
        if margin > 0 { return at + "safe limit \(trip.safe)% − \(margin)" }
        return at + "safe limit \(PaceFormat.awkNumber(trip.limit))%"
    }

    /// What the verdict was judged against: the safe limit per window (less
    /// any margin, `5h 97% − 3`), a cap, or with both, the cap and the
    /// margined safe limits, of which each window takes the lower.
    private func capNote() -> String {
        let safe = "safe limit " + bindingRows.map {
            "\($0.label) \(PaceRules.safeLimit($0))%" + (margin > 0 ? " − \(margin)" : "")
        }.joined(separator: ", ")
        switch cap {
        case .safe:
            return safe
        case .value(let text):
            return margin > 0 ? "cap \(text)%, \(safe)" : "cap \(text)%"
        }
    }

    private func summary() -> String {
        bindingRows.map { "\($0.label) \(String(format: "%.0f", $0.percent))%" }.joined(separator: ", ")
    }

    private func writeState(_ status: String, trip: String = "", percent: String? = nil,
                            resets: String? = nil, note: String) {
        PaceStateFile(path: statePath).write(.init(
            status: status, tripWindow: trip, model: model, cap: cap, eta: eta, window: window,
            modelAuto: modelAuto, margin: margin, usedPercent: percent, resetsIn: resets,
            note: note + autoNoteText()), now: io.now())
    }

    /// What went wrong, and how loudly: `off` is ordinary; `auth` and `http`
    /// are misconfigurations a run must not mistake for "no limits".
    private func apiOffNote() {
        switch fetchReason ?? "off" {
        case "auth":
            io.err("pace: Pacer requires a token and this one was rejected. Set PACE_TOKEN to the token in Pacer → Settings → Integrations. NOT gating — fix this or the run is unpaced.\n")
        case "http":
            io.err("pace: Pacer answered HTTP \(httpCode.isEmpty ? "?" : httpCode) at \(api)\(httpBody.isEmpty ? "" : ": \(httpBody)"). NOT gating.\n")
        case "empty":
            io.out("pace: Pacer answered but reported no rate-limit windows yet — it may not have polled since launch. Proceeding ungated.\n")
        default:
            io.out("pace: no Pacer to read — nothing answered at \(api) and Pacer's data could not be opened. Proceeding ungated.\n")
        }
    }

    private var offExitCode: Int32 {
        switch fetchReason ?? "off" {
        case "auth", "http": return 4
        default: return 2
        }
    }

    // MARK: - Commands

    private func cmdReport() throws {
        guard fetchRows() else { apiOffNote(); throw PaceExit(code: offExitCode) }
        try requireSelection()
        if !autoNote.isEmpty { io.out("pace: \(autoNote)\n") }
        let multi = Set(rows.map(\.account)).count > 1
        let now = io.now()
        for row in selectedRows {
            let prefix = multi ? Self.pad(String(row.account.prefix(8)), 8) + " " : ""
            var rate = ""
            if let recent = row.recentBurn {
                rate = " · \(PaceFormat.signed(recent))%/h now"
                // The engine's smoothed slope beside the measured half-hour
                // rate, when they disagree enough to tell a burst from a climb.
                if let burn = row.burn,
                   abs(PaceFormat.number(recent) - PaceFormat.number(burn)) > 5 {
                    rate += " (\(PaceFormat.signed(burn)) avg)"
                }
            } else if let burn = row.burn {
                rate = " · \(PaceFormat.signed(burn))%/h"
            }
            let full = (row.willHit == "1" && row.hitEta != nil) ? " · full in \(PaceFormat.human(row.hitEta))" : ""
            var mine = ""
            if !model.isEmpty, model != "all", !row.model.isEmpty,
               !PaceRules.binds(windowModel: row.model, wanted: model) {
                mine = "  — binds \(row.model) only"
            }
            io.out(prefix + Self.pad(row.label, 10) + " " + Self.pad(PaceFormat.percent(row.percentText), 4, right: true)
                   + "% used" + rate + full + " · resets in " + Self.pad(PaceFormat.human(row.resetsIn), 7)
                   + " (" + PaceFormat.clock(row.resetsIn, now: now) + ")" + mine + "\n")
        }
    }

    private func cmdJSON() throws {
        guard fetchRows() else {
            io.out("{\"ok\": false, \"reason\": \"\(fetchReason ?? "off")\"}\n")
            throw PaceExit(code: offExitCode)
        }
        try requireSelection()
        // Whose windows these are, and since when that login has been signed
        // in, so a loop can see a switch without diffing accounts (#184).
        let selected = selectedRows
        let acct = selected.first?.account ?? ""
        let since = (!acct.isEmpty && acct == sessionAccount) ? sessionAccountSince : ""
        var text = "{\n  \"ok\": true,\n  \"at\": \"\(PaceFormat.utcStamp(io.now()))\",\n"
        text += "  \"account\": \(acct.isEmpty ? "null" : "\"\(acct)\""),\n"
        text += "  \"accountSince\": \(since.isEmpty ? "null" : "\"\(since)\""),\n  \"windows\": [\n"
        text += selected.map { row in
            "    {\"account\": \"\(row.account)\", \"identity\": \"\(row.identity)\", \"label\": \"\(row.label)\", "
            + "\"model\": \"\(row.model)\", \"usedPercent\": \(row.percentText), "
            + "\"resetsInSeconds\": \(row.resetsIn ?? "null"), "
            + "\"willHitLimit\": \(PaceFormat.number(row.willHit) == 1 ? "true" : "false"), "
            + "\"hitEtaSeconds\": \(row.hitEta ?? "null"), \"burnPercentPerHour\": \(row.burn ?? "null"), "
            + "\"recentBurnPercentPerHour\": \(row.recentBurn ?? "null"), "
            + "\"sampleAgeSeconds\": \(row.sampleAge ?? "null"), \"safeLimit\": \(PaceRules.safeLimit(row)), "
            + "\"binds\": \(PaceRules.binds(windowModel: row.model, wanted: model) ? "true" : "false")}"
        }.joined(separator: ",\n")
        if !selected.isEmpty { text += "\n" }
        text += "  ]\n}\n"
        io.out(text)
    }

    private func cmdGate() throws {
        if stateIsSessionDefault { PaceStateFile.pruneSessionFiles(beside: statePath, now: io.now()) }
        guard fetchRows() else {
            writeState("unknown", note: "not gating (\(fetchReason ?? "off"))")
            apiOffNote()
            if (fetchReason ?? "off") == "off" { io.out("pace: no Pacer — proceeding ungated.\n") }
            throw PaceExit(code: offExitCode)
        }
        try requireSelection()
        guard let trip = PaceRules.evaluate(bindingRows, cap: cap, margin: margin, horizon: eta) else {
            writeState("go", note: "\(summary()) (\(capNote()))")
            io.out("pace: GO — \(summary()) (\(capNote())).\(autoNoteText())\(scopeCaveat())\n")
            throw PaceExit(code: 0)
        }
        writeState("paused", trip: trip.label, percent: trip.percentText, resets: trip.resetsIn,
                   note: "\(tripReason(trip)); resets in \(PaceFormat.human(trip.resetsIn))")
        io.out("pace: PAUSE — \(tripReason(trip)), resets in \(PaceFormat.human(trip.resetsIn)) (\(PaceFormat.clock(trip.resetsIn, now: io.now()))).\(autoNoteText())\n")
        throw PaceExit(code: 10)
    }

    /// Why a verdict cannot be obeyed as it stands.
    private enum Staleness {
        case missing
        case old(age: Int)
        case expired(trip: String)

        /// For the line saying it was re-gated.
        var reason: String {
            switch self {
            case .missing: return "no verdict yet"
            case .old(let age): return "the verdict was \(age < 60 ? "\(age)s" : "\(age / 60)m") old"
            case .expired(let trip): return "the \(trip.isEmpty ? "window" : trip) pause had expired"
            }
        }
    }

    private func staleness(_ state: PaceStateFile) -> Staleness? {
        guard state.exists else { return .missing }
        guard let age = state.age(now: io.now()) else { return nil }
        if age > maxAge { return .old(age: age) }
        if state.quoted("status") == "paused",
           let resetIn = state.bare("resetsInSeconds"), let secs = Int(resetIn), resetIn.allSatisfy(\.isNumber),
           age >= secs {
            return .expired(trip: state.quoted("tripWindow") ?? "")
        }
        return nil
    }

    /// Why this caller cannot take that verdict, or nil if it can: it is about
    /// another model, or another margin.
    private func mismatch(_ state: PaceStateFile) -> String? {
        // `--model auto` takes a verdict gated by `auto` without asking Pacer
        // anything; otherwise the session's model is looked up to compare.
        let bothAuto = model == "auto" && state.bare("autoModel") == "true"
        if model == "auto", !bothAuto { prepare() }
        // A verdict is only about the model it was gated for.
        let gatedModel = state.quoted("model") ?? ""
        if !bothAuto, !model.isEmpty, model != "all", gatedModel != model {
            return "unknown: last gate was for '\(gatedModel.isEmpty ? "every model" : gatedModel)', not '\(model)' — re-gate."
        }
        // So is a margin: a verdict gated at the safe limit says nothing about
        // a caller who wanted to stop three points short of it (#263).
        let gatedMargin = state.bare("margin").flatMap { Int($0) } ?? 0
        if given.contains("margin"), gatedMargin != margin {
            return "unknown: last gate was with margin \(gatedMargin), not \(margin) — re-gate."
        }
        return nil
    }

    private func cmdStatus() throws {
        let state = PaceStateFile(path: statePath)
        // Lanes run for 15-60 minutes and a verdict goes stale in 15, so a
        // lane that only reads went blind partway through (#266). A stale,
        // expired or missing verdict is re-gated here, by one reader for all
        // of them. Not one for another model or margin: re-gating that with
        // its own settings would give this caller the same refusal, and with
        // this caller's, would take the verdict away from its owner.
        if !noRefresh, let stale = staleness(state) {
            if case .missing = stale { refresh(stale) } else if mismatch(state) == nil { refresh(stale) }
        }
        guard state.exists else {
            io.out("pace: no state file (\(statePath)) — run 'gate' first.\n")
            throw PaceExit(code: 3)
        }
        // A verdict has a shelf life: a crashed orchestrator's last word is a
        // snapshot of a window that has since moved.
        let age = state.age(now: io.now())
        if let age, age > maxAge {
            io.out("stale: last gated \(age / 60)m ago (max \(maxAge)s) — treat as unknown and re-gate.\n")
            throw PaceExit(code: 3)
        }
        if let refusal = mismatch(state) {
            io.out(refusal + "\n")
            throw PaceExit(code: 3)
        }
        let status = state.quoted("status") ?? ""
        // A pause ends when the window that caused it resets, whatever its
        // shelf life says.
        if case .expired(let trip)? = staleness(state) {
            io.out("stale: the \(trip.isEmpty ? "window" : trip) pause has expired — that window reset since; re-gate.\n")
            throw PaceExit(code: 3)
        }
        switch status {
        case "go":
            io.out("go\n")
            throw PaceExit(code: 0)
        case "paused":
            io.out("paused: \(state.quoted("note") ?? "")\n")
            throw PaceExit(code: 10)
        default:
            io.out("unknown\n")
            throw PaceExit(code: 3)
        }
    }

    /// How many times, 0.1 s apart, a reader that lost the race waits for the
    /// winner's verdict: about 3 s.
    static let refreshNaps = 30

    /// Re-gate a stale or missing verdict, single-flight (#266): of the
    /// readers that find it stale, the one that takes the lock beside the
    /// state file reads Pacer and writes the verdict; the rest wait briefly
    /// for it, and give up (exit 3, as before) if it does not come. So the
    /// cost is one read of Pacer per staleness period, however many lanes.
    private func refresh(_ stale: Staleness) {
        let lock = PaceRefreshLock(path: PaceStateFile(path: statePath).lockPath)
        defer { lock.release() }
        for attempt in 0...Self.refreshNaps {
            switch lock.acquire() {
            case .unavailable:
                // Nowhere to put a lock is nowhere to put a verdict either.
                return
            case .acquired:
                // Another reader may have re-gated while this one waited.
                if staleness(PaceStateFile(path: statePath)) == nil { return }
                regate(stale)
                if staleness(PaceStateFile(path: statePath)) == nil {
                    io.err("pace: \(stale.reason) — re-gated.\n")
                }
                return
            case .held:
                if attempt == Self.refreshNaps { return }
                io.nap(0.1)
                if staleness(PaceStateFile(path: statePath)) == nil {
                    io.err("pace: \(stale.reason) — another reader re-gated it.\n")
                    return
                }
            }
        }
    }

    /// A gate by the stale verdict's own settings (a missing one's are this
    /// call's), its line unprinted: `status` answers from the file it writes.
    private func regate(_ stale: Staleness) {
        if case .missing = stale { defaultModel() } else { inherit(from: PaceStateFile(path: statePath), force: true) }
        prepare()
        let shown = io
        io.out = { _ in }
        defer { io = shown }
        do { try cmdGate() } catch {}
    }

    /// What a `wait` was not told, it takes from the verdict it is waiting
    /// out (#258). A gate that paused on `--eta 1h` or `--cap 85`, followed by
    /// a bare `wait` as the skill's protocol says, used to judge by the safe
    /// limit alone and "resume" at once, so an orchestrator looped gate →
    /// pause → wait → resume → gate. Flags and PACE_MODEL still win.
    private func inheritFromGate() {
        let state = PaceStateFile(path: statePath)
        guard state.exists else { return }
        let taken = inherit(from: state, force: false)
        // Resolved after, not inside: a refresh adopts `auto` before the
        // session has been looked up.
        resolveAutoModel()
        if !taken.isEmpty {
            io.out("pace: waiting by the gate's settings (\(taken.joined(separator: ", "))).\n")
        }
    }

    /// Take a verdict's gating settings: those this call was not given, or
    /// with `force` (a refresh, #266), all of them. Returns the ones that
    /// changed anything, as flags. An `auto` model is left for the caller to
    /// resolve.
    @discardableResult
    private func inherit(from state: PaceStateFile, force: Bool) -> [String] {
        var taken: [String] = []
        if force || !given.contains("cap"), let raw = state.bare("cap"), !raw.isEmpty {
            if !raw.contains("safe") {
                cap = .value(raw)
                taken.append("--cap \(raw)")
            } else {
                cap = .safe
            }
        }
        if force || !given.contains("margin"), let raw = state.bare("margin"), let points = Int(raw) {
            margin = points
            if points > 0 { taken.append("--margin \(points)") }
        }
        if force || !given.contains("eta"), let raw = state.bare("eta"), let seconds = Int(raw) {
            eta = seconds
            if seconds > 0 { taken.append("--eta \(PaceFormat.human(seconds))") }
        }
        if force || !given.contains("model") {
            if state.bare("autoModel") == "true" {
                // Asked again, not reused: which models the session runs
                // changes while it waits.
                model = "auto"
                autoNote = ""
                taken.append("--model auto")
            } else if let m = state.quoted("model"), force || !m.isEmpty {
                model = m
                modelAuto = false
                autoNote = ""
                if !m.isEmpty { taken.append("--model \(m)") }
            }
        }
        if force || !given.contains("window"), let w = state.quoted("window"), !w.isEmpty {
            window = w
            if w != "all" { taken.append("--window \(w)") }
        }
        return taken
    }

    private func cmdWait() throws {
        inheritFromGate()
        var waiting = false, everRead = false, fails = 0
        var startedOn = ""
        // A switch restores headroom at once and Pacer sees it within
        // seconds, so a waiter looks more often than a reading changes (#184).
        if !intervalSet { interval = 15 }
        while true {
            refreshScope()
            if !fetchRows() {
                // A blip is not a reset: Pacer restarts itself for updates, and
                // "the server went away" at 95% must not read as "go ahead".
                if everRead, (fetchReason ?? "off") != "auth" {
                    fails += 1
                    if fails * interval < maxAge {
                        if fails == 1 {
                            io.out("pace: Pacer stopped answering (\(fetchReason ?? "off")) — holding the pause, not resuming.\n")
                        }
                        io.sleep(TimeInterval(interval))
                        continue
                    }
                }
                writeState("unknown", note: "Pacer unreadable while waiting (\(fetchReason ?? "off"))")
                apiOffNote()
                if (fetchReason ?? "off") == "off" { io.out("pace: cannot gate; proceeding ungated.\n") }
                throw PaceExit(code: offExitCode)
            }
            everRead = true
            fails = 0
            let nowOn = rows.first?.account ?? ""
            if startedOn.isEmpty { startedOn = nowOn }
            try requireSelection()
            guard let trip = PaceRules.evaluate(bindingRows, cap: cap, margin: margin, horizon: eta) else {
                // Why the headroom came back matters: a reset is the window
                // rolling over, a switch is another login's window entirely.
                if !startedOn.isEmpty, nowOn != startedOn {
                    writeState("go", note: "account switched — headroom on \(nowOn.prefix(8)) (\(summary()))")
                    io.out("pace: account switched (\(startedOn.prefix(8)) → \(nowOn.prefix(8))) — headroom on the new login (\(summary())). Resume.\n")
                } else {
                    writeState("go", note: "headroom restored (\(summary()))")
                    if waiting { io.out("pace: reset — headroom restored (\(summary())). Resume.\n") }
                }
                throw PaceExit(code: 0)
            }
            if let secs = trip.resetsIn.flatMap(PaceFormat.integer), secs > maxWait {
                writeState("paused", trip: trip.label, percent: trip.percentText, resets: trip.resetsIn,
                           note: "manual: \(trip.label) resets in \(PaceFormat.human(trip.resetsIn)) (> max-wait \(PaceFormat.human(maxWait))) — checkpoint & stop")
                io.out("pace: \(tripReason(trip)) and resets in \(PaceFormat.human(trip.resetsIn)) — beyond max-wait. Checkpoint and stop; resume after \(PaceFormat.clock(trip.resetsIn, now: io.now())).\n")
                throw PaceExit(code: 20)
            }
            writeState("paused", trip: trip.label, percent: trip.percentText, resets: trip.resetsIn,
                       note: "waiting for \(trip.label) reset (~\(PaceFormat.human(trip.resetsIn)))")
            if !waiting {
                io.out("pace: \(tripReason(trip)) — waiting ~\(PaceFormat.human(trip.resetsIn)) for reset (\(PaceFormat.clock(trip.resetsIn, now: io.now())))…\n")
            }
            waiting = true
            io.sleep(TimeInterval(interval))
        }
    }

    /// The limit `gate` would apply to each binding window, one per line
    /// (`5h         97`), for scripts (#263): the safe limit, less `--margin`,
    /// capped by `--cap`. The model note goes to stderr so stdout stays two
    /// columns.
    private func cmdSafecap() throws {
        guard fetchRows() else { apiOffNote(); throw PaceExit(code: offExitCode) }
        try requireSelection()
        if !autoNote.isEmpty { io.err("pace: \(autoNote)\n") }
        for row in bindingRows {
            io.out(Self.pad(row.label, 10) + " "
                   + PaceFormat.awkNumber(PaceRules.limit(row, cap: cap, margin: margin)) + "\n")
        }
    }

    /// How many accounts, on what plan, with how many sessions drawing on
    /// each, and where each window stands. One read of `/metrics`.
    private func cmdAccounts() throws {
        guard let response = get(api), !response.body.isEmpty else {
            apiOffNote()
            throw PaceExit(code: offExitCode)
        }
        var order: [String] = []
        var plan: [String: String] = [:], active: [String: String] = [:]
        var live: [String: String] = [:], windows: [String: [String]] = [:]
        func note(_ a: String) { if !order.contains(a) { order.append(a) } }
        for p in PaceMetricsText.parse(response.body) {
            let a = p.label("account")
            switch p.name {
            case "pacer_account_info":
                note(a)
                plan[a] = p.label("plan")
                active[a] = p.label("active")
            case "pacer_account_active_sessions":
                live[a] = p.raw
            case "pacer_rate_limit_used_ratio":
                note(a)
                let w = p.label("window")
                let label: String
                if w == "five_hour" { label = "5h" }
                else if w == "seven_day" { label = "7d" }
                else {
                    let parts = w.split(separator: "|", omittingEmptySubsequences: false)
                    label = parts.count >= 2 && !parts[1].isEmpty ? String(parts[1]) : String(parts.first ?? "")
                }
                windows[a, default: []].append("\(label) \(Int(p.value * 100 + 0.5))%")
            default:
                break
            }
        }
        guard !order.isEmpty else {
            io.out("pace: Pacer reports no accounts yet.\n")
            return
        }
        var text = "\(order.count) account\(order.count == 1 ? "" : "s")\n"
        for a in order {
            let planText = (plan[a] ?? "").isEmpty ? "plan unknown" : plan[a]!
            text += "\n  " + Self.pad(String(a.prefix(8)), 10) + " " + planText
                + (active[a] == "true" ? " · active login" : "") + "\n"
            let count = live[a] ?? "0"
            text += "    \(count) session\(PaceFormat.number(count) == 1 && live[a] != nil ? "" : "s") drawing on it now\n"
            if let w = windows[a], !w.isEmpty { text += "    " + w.joined(separator: "  ") + "\n" }
        }
        text += "\nA window is account-wide: every session above draws on the same percentage.\n"
        io.out(text)
    }

    /// Where the other sessions are. The branch is read here, at the moment
    /// of asking: it changes without producing a turn for Pacer to notice.
    ///
    /// Decoded as JSON rather than line by line. `pace.sh`'s awk also treated
    /// the response's closing brace as the end of a session, so it printed
    /// the last session twice.
    private func cmdSessions() throws {
        guard let response = get(apiBase + "/v1/sessions", query: scope),
              response.body.contains("\"sessions\"") else {
            apiOffNote()
            throw PaceExit(code: offExitCode)
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(response.body.utf8))) as? [String: Any]
        let sessions = object?["sessions"] as? [[String: Any]] ?? []
        var printed = false
        for s in sessions {
            func str(_ key: String) -> String { s[key] as? String ?? "" }
            let project = str("project"), path = str("projectPath")
            guard !project.isEmpty || !path.isEmpty else { continue }
            let current = str("currentAccountId")
            let acct = String((current.isEmpty ? str("accountId") : current).prefix(8))
            let modelName = str("model").isEmpty ? "?" : str("model")
            var branch = ""
            var isDir: ObjCBool = false
            if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
               let b = io.gitBranch(path), !b.isEmpty {
                branch = " (\(b))"
            }
            var whereText = project + branch
            // Truncated rather than shoving every later column out of line;
            // the full path is on the same row.
            if whereText.count > 34 { whereText = String(whereText.prefix(33)) + "…" }
            let repo = str("repository")
            io.out(Self.pad(str("activity"), 7) + " " + Self.pad(acct, 9) + " " + Self.pad(whereText, 34) + " "
                   + Self.pad(modelName, 18) + " " + path + (repo.isEmpty ? "" : "  ← \(repo)") + "\n")
            printed = true
        }
        if !printed { io.out("No sessions in the last hour.\n") }
    }

    /// `printf '%-Ns'` / `'%Ns'`.
    static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, width - s.count))
        return right ? fill + s : s + fill
    }
}
