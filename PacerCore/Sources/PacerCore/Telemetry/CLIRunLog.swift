import Foundation

/// One line per `pacer` command start and end, in a small file in the App
/// Group container, so the app can report what the CLI does: which commands
/// run, how long they take, how they exit, and which never finished.
///
/// **Why a file and not telemetry from the CLI itself.** Agents run `pacer`
/// constantly (a `gate` or `status` every wave), so the CLI must stay a fast,
/// offline process: no SDK start, no network, no flush on exit. And many run
/// at once, so a defaults read-modify-write counter would lose updates. One
/// `O_APPEND` write per line, well under `PIPE_BUF`, cannot interleave. The
/// app reads it back once a day for the check-in (`summary(since:)`).
///
/// **What a line holds**: time, `start`/`end`, a random run id that pairs
/// them, the subcommand name, and on `end` the exit code, milliseconds, and
/// whether it answered from the app's local API or the store directly. A
/// `start` line may also carry the NAMES of the flags given (`flags=cap,model`,
/// only names the CLI defines; `flagNames`), never their values.
/// Never arguments, account names, paths or output.
///
///     2026-11-02T16:03:12.345Z start 9f2c1a04 gate flags=cap,model
///     2026-11-02T16:03:12.401Z end 9f2c1a04 gate exit=0 ms=56 src=api
public enum CLIRunLog {

    public static let fileName = "cli-runs.log"
    public static let byteCap = 512 * 1024

    /// A `start` with no `end` after this long counts as a hung run. `wait`
    /// is long by design and has its own max-wait, so it is exempt.
    public static let hungAfter: TimeInterval = 10 * 60
    public static let longRunning: Set<String> = ["wait"]

    public enum Source: String, Sendable { case api, offline, none }

    public enum Kind: String, Sendable { case start, end }

    public struct Line: Sendable, Equatable {
        public let at: Date
        public let kind: Kind
        public let runId: String
        public let subcommand: String
        public let exitCode: Int32?
        public let milliseconds: Int?
        public let source: String?
        /// Flag names on a `start` line; empty when none were given.
        public var flags: [String] = []
    }

    public static func defaultURL() -> URL? {
        try? PacerStore.sharedContainerURL().appendingPathComponent(fileName)
    }

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Only names the CLI defines: anything else is recorded as `other`, so an
    /// argument typed in the subcommand position never reaches the log.
    public static func safeName(_ subcommand: String, known: Set<String>) -> String {
        known.contains(subcommand) ? subcommand : "other"
    }

    /// The names of the flags in `arguments` (`--cap 50 --model opus` gives
    /// `cap,model`), deduplicated and sorted. A value is never a name: an
    /// argument that does not start with `-` is skipped, `--x=value` keeps
    /// `x`, and a name the CLI does not define (or a negative number given
    /// as a value) becomes `other`. `-h` is `help`.
    public static func flagNames(_ arguments: [String], known: Set<String>) -> [String] {
        var names = Set<String>()
        for arg in arguments where arg.hasPrefix("-") && arg.count > 1 {
            var name = String(arg.drop { $0 == "-" })
            if let eq = name.firstIndex(of: "=") { name = String(name[..<eq]) }
            if name == "h" { name = "help" }
            names.insert(known.contains(name) ? name : "other")
        }
        return names.sorted()
    }

    public static func newRunId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    // MARK: - Writing (CLI process)

    public static func recordStart(runId: String, subcommand: String, flags: [String] = [],
                                   at: Date = Date(), to url: URL? = defaultURL()) {
        let suffix = flags.isEmpty ? "" : " flags=\(flags.joined(separator: ","))"
        append("\(stamp.string(from: at)) start \(runId) \(subcommand)\(suffix)", to: url)
    }

    public static func recordEnd(runId: String, subcommand: String, exitCode: Int32,
                                 milliseconds: Int, source: Source, at: Date = Date(),
                                 to url: URL? = defaultURL()) {
        append("\(stamp.string(from: at)) end \(runId) \(subcommand) exit=\(exitCode) ms=\(milliseconds) src=\(source.rawValue)",
               to: url)
    }

    private static func append(_ text: String, to url: URL?) {
        guard let url else { return }
        let data = Data((text + "\n").utf8)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var info = stat()
        let size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        close(fd)
        if written > 0, size > byteCap { WidgetRefreshLog.trim(url, keeping: byteCap / 2) }
    }

    // MARK: - Reading (app process)

    public static func parse<S: StringProtocol>(_ text: S) -> Line? {
        let parts = text.split(separator: " ")
        guard parts.count >= 4, let at = stamp.date(from: String(parts[0])),
              let kind = Kind(rawValue: String(parts[1])) else { return nil }
        var fields: [String: String] = [:]
        for p in parts.dropFirst(4) {
            let kv = p.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        if kind == .end, fields["exit"] == nil || fields["ms"] == nil { return nil }
        return Line(at: at, kind: kind, runId: String(parts[2]), subcommand: String(parts[3]),
                    exitCode: fields["exit"].flatMap { Int32($0) },
                    milliseconds: fields["ms"].flatMap { Int($0) }, source: fields["src"],
                    flags: fields["flags"].map { $0.split(separator: ",").map(String.init) } ?? [])
    }

    public static func lines(at url: URL? = defaultURL()) -> [Line] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { parse($0) }
    }

    // MARK: - Daily summary

    public struct CommandStats: Sendable, Equatable {
        public var runs = 0
        public var failures = 0        // exit code 1 (error) or 4 (misconfigured)
        public var hung = 0
        public var durationsMs: [Int] = []
        public var bySource: [String: Int] = [:]
    }

    /// Per subcommand, for runs that started in `[since, until)`. A start with
    /// no end older than `hungAfter` at `until` is a hung run (except
    /// `longRunning`); a start with no end that is younger is still running
    /// and not counted yet.
    public static func summary(_ lines: [Line], since: Date, until: Date) -> [String: CommandStats] {
        var ends: [String: Line] = [:]
        for l in lines where l.kind == .end { ends[l.runId] = l }
        var out: [String: CommandStats] = [:]
        for s in lines where s.kind == .start && s.at >= since && s.at < until {
            var stats = out[s.subcommand] ?? CommandStats()
            if let e = ends[s.runId] {
                stats.runs += 1
                if let code = e.exitCode, code == 1 || code == 4 { stats.failures += 1 }
                if let ms = e.milliseconds { stats.durationsMs.append(ms) }
                if let src = e.source { stats.bySource[src, default: 0] += 1 }
            } else if until.timeIntervalSince(s.at) >= hungAfter, !longRunning.contains(s.subcommand) {
                stats.runs += 1
                stats.hung += 1
            } else {
                continue
            }
            out[s.subcommand] = stats
        }
        return out
    }

    // MARK: - Per-run (PostHog `cli_command`)

    public enum Outcome: String, Sendable { case ok, failure, misconfigured, hung, other }

    public struct Run: Sendable, Equatable {
        public let at: Date
        public let subcommand: String
        public let flags: [String]
        public let outcome: Outcome
        /// The exit code when it is not 0, 1 or 4 (gate and wait use 2 and 3
        /// as answers), else nil.
        public let exitCode: Int32?
        public let milliseconds: Int?
        public let source: String?
    }

    /// Finished (or hung) runs that started in `[since, until)`, oldest
    /// first, with the same pairing and hung rule as `summary`.
    public static func runs(_ lines: [Line], since: Date, until: Date) -> [Run] {
        var ends: [String: Line] = [:]
        for l in lines where l.kind == .end { ends[l.runId] = l }
        var out: [Run] = []
        for s in lines where s.kind == .start && s.at >= since && s.at < until {
            if let e = ends[s.runId] {
                let code = e.exitCode ?? -1
                let outcome: Outcome = switch code {
                case 0: .ok
                case 1: .failure
                case 4: .misconfigured
                default: .other
                }
                out.append(Run(at: s.at, subcommand: s.subcommand, flags: s.flags, outcome: outcome,
                               exitCode: outcome == .other ? e.exitCode : nil,
                               milliseconds: e.milliseconds, source: e.source))
            } else if until.timeIntervalSince(s.at) >= hungAfter, !longRunning.contains(s.subcommand) {
                out.append(Run(at: s.at, subcommand: s.subcommand, flags: s.flags, outcome: .hung,
                               exitCode: nil, milliseconds: nil, source: nil))
            }
        }
        return out.sorted { $0.at < $1.at }
    }
}
