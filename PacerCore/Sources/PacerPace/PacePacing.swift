import Foundation

/// How much an agent is told: only whether to stop, or the numbers too.
///
/// **Why gate-only is the default inside a session.** Agents that read a
/// window's percentage used it to plan: they kept fan-outs lean, picked a
/// weaker model, or deferred work "to save the weekly window", none of which
/// the owner asked for. With several logins rotating, one login's 68% is not
/// even the machine's capacity. Pacer's job in an agent's work is to stop it
/// gracefully at a limit, so in a Claude Code session `gate`, `status` and
/// `wait` say go, pause or resume, and how to wait, with no percentages.
/// `informed` restores the numbers for a session or a repo whose owner wants
/// agents to plan with them. A terminal (no session id) is a person, and
/// gets the numbers as before.
enum PacingMode: String, Sendable {
    case gate
    case informed

    /// Where the mode came from, for `pacer mode`.
    enum Source: Equatable, Sendable {
        case flag
        case sessionFile
        case environment
        case sessionDefault
        case terminalDefault

        var text: String {
            switch self {
            case .flag: return "--pacing"
            case .sessionFile: return "set for this session with `pacer mode`"
            case .environment: return "PACER_PACING (this session's environment, or a settings.json \"env\")"
            case .sessionDefault: return "the default inside a Claude Code session"
            case .terminalDefault: return "the default outside a Claude Code session"
            }
        }
    }

    /// `gate-only` / `informed`, as `pacer mode` prints it.
    var title: String { self == .gate ? "gate-only" : "informed" }

    /// Accepts the two names, and `gate-only` for `gate`.
    init?(name: String) {
        switch name.lowercased() {
        case "gate", "gate-only", "gateonly": self = .gate
        case "informed": self = .informed
        default: return nil
        }
    }

    /// What resolving found: the mode, where it came from, and anything
    /// unusable it skipped, for one line on stderr.
    struct Resolution: Equatable, Sendable {
        let mode: PacingMode
        let source: Source
        var warnings: [String] = []
    }

    /// Precedence: `--pacing`, then `PACER_PACING`, then a `pacer mode`
    /// choice for this session, then the default: gate-only in a session,
    /// informed outside.
    ///
    /// **The environment outranks the session file** because it is the
    /// user's setting (a repo's `.claude/settings.json` `"env"`, or a launch
    /// for one session), and `pacer mode` is a command an agent can run: an
    /// agent in a repo set to gate-only must not be able to opt itself into
    /// the numbers. The file only decides when the environment says nothing.
    ///
    /// **Nothing unusable fails a run.** A typo in `PACER_PACING`, or a mode
    /// file someone cut short, used to make every `gate`, `status` and `wait`
    /// exit 1, outside the 0/10/20/2 contract briefs and `pace-guard.sh`
    /// depend on. Such a value is skipped with a warning, and the next source
    /// decides. Only `--pacing`, named on the command itself, is an error.
    static func resolve(flag: String?, environment: [String: String],
                        sessionFile: String?) throws -> Resolution {
        if let flag {
            guard let mode = PacingMode(name: flag) else { throw PacingError.unknown(flag, "--pacing") }
            return Resolution(mode: mode, source: .flag)
        }
        var warnings: [String] = []
        if let raw = environment["PACER_PACING"], !raw.isEmpty {
            if let mode = PacingMode(name: raw) {
                return Resolution(mode: mode, source: .environment)
            }
            warnings.append("PACER_PACING '\(raw)' is not a pacing mode (gate or informed); ignoring it")
        }
        if let path = sessionFile {
            switch PaceModeFile(path: path).read() {
            case .mode(let mode):
                return Resolution(mode: mode, source: .sessionFile, warnings: warnings)
            case .unreadable:
                warnings.append("the pacing mode file \(path) is unreadable; ignoring it (`pacer mode clear` removes it)")
            case .absent:
                break
            }
        }
        let inSession = !(environment["CLAUDE_CODE_SESSION_ID"] ?? "").isEmpty
        return Resolution(mode: inSession ? .gate : .informed,
                          source: inSession ? .sessionDefault : .terminalDefault, warnings: warnings)
    }

    enum PacingError: Error, CustomStringConvertible {
        case unknown(String, String)
        var description: String {
            switch self {
            case .unknown(let value, let source):
                return "\(source) '\(value)' is not a pacing mode (gate or informed)"
            }
        }
    }
}

/// `~/.claude/pace/mode-session-<first 8 of the session id>.json`: the mode a
/// `pacer mode informed|gate` chose for one Claude Code session, used only
/// when `PACER_PACING` is unset. Removed with
/// `pacer mode clear`, and after a week untouched like the session's state
/// file (`PaceStateFile.pruneSessionFiles`).
struct PaceModeFile {
    let path: String

    static func path(home: String, sessionId: String?) -> String? {
        guard let tag = PaceStateFile.sessionTag(sessionId) else { return nil }
        return "\(home)/.claude/pace/mode-session-\(tag).json"
    }

    enum Contents: Equatable {
        case absent
        case mode(PacingMode)
        /// There, but not a mode this can read: cut short, edited, or not ours.
        case unreadable
    }

    func read() -> Contents {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .unreadable }
        for line in text.split(separator: "\n") where line.contains("\"mode\"") {
            let fields = line.split(separator: "\"", omittingEmptySubsequences: false)
            if fields.count >= 4, let mode = PacingMode(name: String(fields[3])) { return .mode(mode) }
        }
        return .unreadable
    }

    func write(_ mode: PacingMode, now: Date) -> Bool {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let body = "{\n  \"mode\": \"\(mode.rawValue)\",\n  \"updatedAt\": \"\(PaceFormat.utcStamp(now))\"\n}\n"
        return (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

/// What an account-rotation controller says it would do, written every loop
/// to `~/.claude/pace/rotation.json` (or `PACE_ROTATION`). Pacer cannot see
/// the controller otherwise: it knows a switcher exists, not whether one is
/// running, holding, or has a target with room.
///
/// The contract, for any controller:
///
///     {"v": 1, "updatedAt": "2026-11-17T15:06:33Z", "active": "e34c1364",
///      "holding": false, "targets": ["74598a77"]}
///
/// `targets` are the accounts it would switch to now (an id, or the first 8
/// characters of one), by its own bar. A file older than `freshFor` describes
/// a controller that has stopped, and is ignored.
struct PaceRotation: Equatable, Sendable {
    let updatedAt: Date
    let active: String
    let holding: Bool
    let targets: [String]

    /// The controller loops every minute; three missed loops is a stopped one.
    static let freshFor: TimeInterval = 180

    static func path(home: String, environment: [String: String]) -> String {
        if let path = environment["PACE_ROTATION"], !path.isEmpty { return path }
        return "\(home)/.claude/pace/rotation.json"
    }

    /// The heartbeat at `path` if it is there, parses and is fresh at `now`.
    static func read(path: String, now: Date) -> PaceRotation? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stamp = object["updatedAt"] as? String,
              let at = PaceFormat.isoFormatter.date(from: stamp) else { return nil }
        let age = now.timeIntervalSince(at)
        guard age <= freshFor, age > -freshFor else { return nil }
        return PaceRotation(updatedAt: at, active: object["active"] as? String ?? "",
                            holding: object["holding"] as? Bool ?? false,
                            targets: (object["targets"] as? [String] ?? []).filter { !$0.isEmpty })
    }

    /// Targets other than the accounts being judged, matched loosely: the
    /// controller names an account by the first 8 hex of its org id.
    func targets(excluding accounts: [String]) -> [String] {
        targets.filter { target in !accounts.contains { Self.same($0, target) } }
    }

    /// Whether a switch off `accounts` onto a login with room is coming.
    func expectsSwitch(off accounts: [String]) -> Bool {
        !holding && !targets(excluding: accounts).isEmpty
    }

    static func same(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }
}

/// What can end a pause besides the window's own reset.
enum PaceSwitchOutlook: String, Sendable {
    /// A rotation controller is running and has a target with room.
    case expected
    /// Another login has room, but nothing says a switch is coming.
    case possible
    /// No other login has room.
    case none
}
