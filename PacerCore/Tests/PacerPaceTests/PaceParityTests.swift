import Foundation
import Testing
@testable import PacerPace

/// The port against the original: `pace.sh` and `Pace.run` on the same
/// fixture and arguments must exit with the same code, print the same text and
/// leave the same state file. Only wall-clock text (`Fri 5:00 PM`, `"at"`,
/// `"updatedAt"`) and the sandbox path are normalised.
///
/// Deliberate differences, not exercised here:
/// - `sessions` lists each session once. `pace.sh`'s awk took the response's
///   closing brace for the end of a session and printed the last one twice.
/// - A non-numeric `--interval`, `--max-wait`, `--max-age` or `--retries` is an
///   error. `pace.sh` let bash arithmetic fail later, at whichever line first
///   used it.
/// - `wait` is not compared: its output depends on how the world changes
///   between polls. `PaceCommandTests` covers it case by case.
/// - With nothing to read, the message says "no Pacer" rather than "API off":
///   the port reads Pacer's data when the API is off, so exit 2 now means
///   there is no Pacer at all. `renamed` maps the script's two sentences.
/// - The state file also records the gate's `eta` and `window`, so a later
///   `wait` judges by the same rules (#258), and whether its model came from
///   `auto` (#264), so that `wait` asks again, the gate's `--margin`
///   (#263), and for a pause, which window tripped on which account at what
///   limit, so a `wait` holds that window until it clears (#267);
///   `withoutAddedKeys` drops those lines from the port's file before
///   comparing.
/// - `status` re-gates a stale, expired or missing verdict (#266); the
///   script only reported it. The port's `status` steps run with
///   `--no-refresh`, which is the script's pure file read, so what they
///   print is still compared.
/// - The port has subcommands the script did not (`safecap`, #263;
///   `feedback`, #268), so its
///   "unknown subcommand" message lists more; `renamed` maps the list.
/// - With `CLAUDE_CODE_SESSION_ID` set and no `--model`, the port gates as
///   `--model auto` (#264); `pace.sh` let every window bind. Not exercised:
///   the harness runs without a session id, where both bind every window.
@Suite("pace: parity with pace.sh")
struct PaceParityTests {

    static var scriptPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PacerPaceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PacerCore
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("PacerCore/Tests/PacerPaceTests/Oracle/pace.sh").path
    }

    /// Every field the parser reads, two logins, fractional percentages, a
    /// reset already due, windows named by model, by surface and by kind.
    static let rich = """
    pacer_account_info{account="org-work",name="Work",plan="Max 20×",tier="default_claude_max_20x",active="true"} 1
    pacer_account_info{account="org-home",name="Home",plan="",active="false"} 1
    pacer_account_active_sessions{account="org-work"} 3
    pacer_account_active_sessions{account="org-home"} 1
    pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.4567
    pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 7322
    pacer_rate_limit_burn_percent_per_hour{account="org-work",window="five_hour"} 12.5
    pacer_rate_limit_recent_burn_percent_per_hour{account="org-work",window="five_hour"} 31.25
    pacer_rate_limit_sample_age_seconds{account="org-work",window="five_hour"} 125
    pacer_rate_limit_will_hit{account="org-work",window="five_hour"} 1
    pacer_rate_limit_hit_eta_seconds{account="org-work",window="five_hour"} 5400
    pacer_rate_limit_used_ratio{account="org-work",window="seven_day"} 0.8333
    pacer_rate_limit_reset_seconds{account="org-work",window="seven_day"} 400000
    pacer_rate_limit_burn_percent_per_hour{account="org-work",window="seven_day"} 1.2
    pacer_rate_limit_used_ratio{account="org-work",window="weekly_scoped|Fable|"} 0
    pacer_rate_limit_reset_seconds{account="org-work",window="weekly_scoped|Fable|"} 400000
    pacer_rate_limit_used_ratio{account="org-work",window="daily|claude-opus-5|web"} 0.5
    pacer_rate_limit_used_ratio{account="org-work",window="something||cli"} 0.25
    pacer_rate_limit_reset_seconds{account="org-work",window="something||cli"} 59
    pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.99
    pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} -5
    pacer_rate_limit_used_ratio{account="org-home",window="seven_day"} 1
    pacer_rate_limit_reset_seconds{account="org-home",window="seven_day"} 90061
    pacer_up 1
    """

    struct Case: CustomTestStringConvertible, Sendable {
        let fixture: String?
        let steps: [[String]]
        let env: [String: String]
        var testDescription: String { steps.map { $0.joined(separator: " ") }.joined(separator: " ; ") }
    }

    static let cases: [Case] = {
        var out: [Case] = []
        let commands: [[String]] = [
            ["report"], ["json"], ["gate"], ["accounts"],
            ["gate", "--cap", "85"], ["gate", "--cap", "45"], ["gate", "--cap", "99.5"],
            ["gate", "--eta", "2h"], ["gate", "--eta", "90m", "--cap", "95"],
            ["gate", "--model", "opus"], ["gate", "--model", "fable"], ["gate", "--model", "claude-opus-5-5"],
            ["report", "--model", "fable"], ["json", "--model", "opus"],
            ["report", "--account", "all"], ["json", "--account", "all"], ["gate", "--account", "all", "--cap", "90"],
            ["report", "--account", "org-home"], ["gate", "--account", "org-h", "--cap", "50"],
            ["json", "--window", "5h"], ["gate", "--window", "7d"], ["report", "--window", "cli"],
            ["gate", "--window", "nope"], ["report", "--window", "weekly_scoped"],
            ["gate", "--eta", "soon"], ["gate", "--bogus"], ["frobnicate"],
            ["status"],
        ]
        for fixture in [PaceFixtures.metrics, rich] {
            for c in commands { out.append(Case(fixture: fixture, steps: [c], env: [:])) }
            // A verdict, then what a subagent reads of it.
            out.append(Case(fixture: fixture, steps: [["gate", "--cap", "85"], ["status"]], env: [:]))
            out.append(Case(fixture: fixture, steps: [["gate", "--cap", "85", "--model", "opus"],
                                                      ["status", "--model", "fable"]], env: [:]))
            out.append(Case(fixture: fixture, steps: [["gate"], ["status", "--model", "opus"]], env: [:]))
            out.append(Case(fixture: fixture, steps: [["gate", "--cap", "85"]],
                            env: ["PACE_MODEL": PaceRules.ambiguousModel]))
            out.append(Case(fixture: fixture, steps: [["report"]],
                            env: ["PACE_MODEL": PaceRules.ambiguousModel]))
            out.append(Case(fixture: fixture, steps: [["json"]], env: ["PACE_ACCOUNT": "org-home"]))
        }
        // Pacer off.
        for c in [["report"], ["json"], ["gate"], ["accounts"], ["sessions"]] {
            out.append(Case(fixture: nil, steps: [c + ["--retries", "1"]], env: [:]))
        }
        return out
    }()

    private struct Outcome: Equatable {
        let status: Int32
        let output: String
        let state: String
    }

    @Test("pace.sh and the port agree", arguments: cases)
    func agree(_ c: Case) throws {
        let script = try runSteps(c) { box, args, env in
            let r = Self.runScript(args, env: env)
            return PaceResult(status: r.status, out: Self.renamed(r.out))
        }
        let port = try runSteps(c) { box, args, env in
            let capture = PaceCapture()
            let io = PaceIO(out: capture.append, err: capture.append, now: Date.init,
                            sleep: { _ in }, get: PaceHTTP.get, gitBranch: { _ in nil })
            let ported = args.first == "status" ? args + ["--no-refresh"] : args
            return PaceResult(status: Pace.run(ported, environment: env, io: io), out: capture.text)
        }.map { Outcome(status: $0.status, output: $0.output, state: Self.withoutAddedKeys($0.state)) }
        #expect(port.count == script.count)
        for (i, (s, p)) in zip(script, port).enumerated() {
            #expect(p.status == s.status, "step \(i): exit \(p.status), pace.sh \(s.status)\n\(s.output)")
            #expect(p.output == s.output, "step \(i) output\n--- pace.sh\n\(s.output)--- port\n\(p.output)")
            #expect(p.state == s.state, "step \(i) state\n--- pace.sh\n\(s.state)--- port\n\(p.state)")
        }
    }

    /// Each step in its own sandbox, then normalised.
    private func runSteps(_ c: Case,
                          _ run: (PaceSandbox, [String], [String: String]) throws -> PaceResult) throws -> [Outcome] {
        let box = try PaceSandbox(metrics: c.fixture)
        var env = ["HOME": box.dir.path, "PATH": "/usr/bin:/bin",
                   "PACER_API": "file://\(box.dir.path)", "PACE_STATE": box.stateURL.path,
                   "PACE_RETRIES": "1"]
        for (k, v) in c.env { env[k] = v }
        return try c.steps.map { args in
            let r = try run(box, args, env)
            return Outcome(status: r.status, output: Self.normalised(r.out, box),
                           state: Self.normalised(box.stateText, box))
        }
    }

    /// The keys the script never wrote.
    static let addedKeys = ["eta", "window", "autoModel", "margin", "tripIdentity", "tripAccount", "tripLimit"]

    /// The port's state file minus the keys the script never wrote.
    static func withoutAddedKeys(_ state: String) -> String {
        state.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !addedKeys.contains { line.contains("\"\($0)\": ") } }
            .joined(separator: "\n")
    }

    /// The script's "API off" wording, as the port now says it.
    static func renamed(_ text: String) -> String {
        text.replacingOccurrences(
                of: #"Pacer API unreachable at (\S+) — it is opt-in and likely just off \(Pacer → Settings → Integrations\)\. Proceed normally\."#,
                with: "pace: no Pacer to read — nothing answered at $1 and Pacer's data could not be opened. Proceeding ungated.",
                options: .regularExpression)
            .replacingOccurrences(of: "pace: API off — proceeding ungated.", with: "pace: no Pacer — proceeding ungated.")
            .replacingOccurrences(of: "(report|json|accounts|sessions|gate|status|wait)",
                                  with: "(\(Pace.subcommands.joined(separator: "|")))")
    }

    static func normalised(_ text: String, _ box: PaceSandbox) -> String {
        var t = text.replacingOccurrences(of: box.dir.path, with: "<dir>")
        t = t.replacingOccurrences(of: #"\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2}:\d{2} (AM|PM)\b"#,
                                   with: "<clock>", options: .regularExpression)
        t = t.replacingOccurrences(of: #""(at|updatedAt)": "[0-9T:Z-]+""#, with: "\"$1\": \"<now>\"",
                                   options: .regularExpression)
        return t
    }

    static func runScript(_ args: [String], env: [String: String]) -> PaceResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + args
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return PaceResult(status: -1, out: "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return PaceResult(status: process.terminationStatus, out: String(decoding: data, as: UTF8.self))
    }
}
