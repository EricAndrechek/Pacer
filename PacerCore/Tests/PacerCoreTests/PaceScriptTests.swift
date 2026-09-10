import Foundation
import Testing
@testable import PacerCore

/// The shipped `pace.sh`, exercised end to end against a fixture.
///
/// The script is the part of the skill that actually has to be right — an
/// orchestrator trusts its exit codes with hours of work — and it is shell, so
/// nothing else type-checks it. `curl` reads `file://` URLs, so pointing
/// `PACER_API` at a directory containing a `metrics` file runs the real code
/// path with no server involved.
@Suite("pace.sh")
struct PaceScriptTests {

    /// One 5-hour block with headroom, a 7-day block, and a scoped per-model
    /// cap that is over any sane threshold — the shape that used to be
    /// invisible to a pacing script.
    private static let metrics = """
    # HELP pacer_rate_limit_used_ratio Current rate-limit utilization (0–1).
    # TYPE pacer_rate_limit_used_ratio gauge
    pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.12
    pacer_rate_limit_used_ratio{account="org-work",window="seven_day"} 0.32
    pacer_rate_limit_used_ratio{account="org-work",window="weekly_scoped|Fable|"} 0.95
    pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.88
    # HELP pacer_rate_limit_reset_seconds Seconds until the rate-limit window resets.
    # TYPE pacer_rate_limit_reset_seconds gauge
    pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 6000
    pacer_rate_limit_reset_seconds{account="org-work",window="seven_day"} 321340
    pacer_rate_limit_reset_seconds{account="org-work",window="weekly_scoped|Fable|"} 321340
    pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 300
    # HELP pacer_account_info Account identity; value is always 1.
    # TYPE pacer_account_info gauge
    pacer_rate_limit_will_hit{account="org-work",window="five_hour"} 1
    pacer_rate_limit_hit_eta_seconds{account="org-work",window="five_hour"} 2700
    pacer_rate_limit_burn_percent_per_hour{account="org-work",window="five_hour"} 24
    pacer_account_info{account="org-work",name="Account work",active="true"} 1
    pacer_account_info{account="org-home",name="Account home",active="false"} 1
    pacer_up 1
    """

    private struct Run {
        let status: Int32
        let out: String
    }

    private static var scriptPath: String {
        // <repo>/PacerCore/Tests/PacerCoreTests/ThisFile.swift → <repo>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PacerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PacerCore
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Skills/pacer/pace.sh").path
    }

    private final class Sandbox {
        let dir: URL
        init(metrics: String?) throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pace-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let metrics {
                try metrics.write(to: dir.appendingPathComponent("metrics"),
                                  atomically: true, encoding: .utf8)
            }
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        var stateURL: URL { dir.appendingPathComponent("state.json") }
        var stateText: String { (try? String(contentsOf: stateURL, encoding: .utf8)) ?? "" }
    }

    /// Minimum HTTP server that answers one status to everything. Enough to
    /// prove the script tells "rejected" apart from "nothing listening".
    private final class StubServer {
        private let task: Process
        let base: String

        init(status: Int, body: String) throws {
            let port = Int.random(in: 49_200...49_900)
            base = "http://127.0.0.1:\(port)"
            let script = """
            import sys
            from http.server import BaseHTTPRequestHandler, HTTPServer
            class H(BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(\(status))
                    self.send_header("Content-Type", "text/plain")
                    self.end_headers()
                    self.wfile.write(b\"\"\"\(body)\"\"\")
                def log_message(self, *a): pass
            HTTPServer(("127.0.0.1", \(port)), H).serve_forever()
            """
            task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["python3", "-c", script]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            // Give it a moment to bind before the script curls it.
            Thread.sleep(forTimeInterval: 0.6)
        }

        func stop() { task.terminate() }
    }

    private func run(_ sandbox: Sandbox, _ args: [String], api: String? = nil,
                     unsetState: Bool = false, extra: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.scriptPath] + args
        var env = ProcessInfo.processInfo.environment
        env["PACER_API"] = api ?? "file://\(sandbox.dir.path)"
        if unsetState { env.removeValue(forKey: "PACE_STATE") }
        else { env["PACE_STATE"] = sandbox.stateURL.path }
        for (key, value) in extra { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus,
                   out: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Reporting

    /// The whole point of the exercise: a per-model cap is a window like any
    /// other, named by the model rather than by its raw composite identity.
    @Test func reportListsEveryWindowOfTheActiveAccount() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["report"])
        #expect(result.status == 0)
        #expect(result.out.contains("5h"))
        #expect(result.out.contains("7d"))
        #expect(result.out.contains("Fable"))
        #expect(result.out.contains("95% used"))
        #expect(result.out.contains("resets in 1h 40m"))
        // org-home is the other login; its 88% must not appear unasked.
        #expect(!result.out.contains("88% used"))
    }

    @Test func anotherAccountIsReadableByName() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["report", "--account", "org-home"])
        #expect(result.status == 0)
        #expect(result.out.contains("88% used"))
        #expect(!result.out.contains("Fable"))
    }

    @Test func jsonCarriesTheFullIdentityAlongsideTheLabel() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["json"])
        #expect(result.status == 0)
        #expect(result.out.contains("\"identity\": \"weekly_scoped|Fable|\""))
        #expect(result.out.contains("\"label\": \"Fable\""))
        #expect(result.out.contains("\"usedPercent\": 95"))
    }

    // MARK: - Gating

    /// The regression this skill exists to prevent: a run that reads only the
    /// two fixed blocks sees 12% and 32% and charges ahead, while the window
    /// that actually gates the work sits at 95%.
    @Test func gateTripsOnAScopedWindowTheFixedBlocksCannotSee() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["gate", "--cap", "85"])
        #expect(result.status == 10)
        #expect(result.out.contains("PAUSE"))
        #expect(result.out.contains("Fable"))
        #expect(box.stateText.contains("\"status\": \"paused\""))
        #expect(box.stateText.contains("\"tripWindow\": \"Fable\""))
    }

    @Test func statusIsAPlainFileReadOfWhatTheGateDecided() throws {
        let box = try Sandbox(metrics: Self.metrics)
        _ = try run(box, ["gate", "--cap", "85"])

        // No metrics available at all — `status` must still answer, because a
        // hundred subagents calling it never touch the network.
        try FileManager.default.removeItem(at: box.dir.appendingPathComponent("metrics"))
        let result = try run(box, ["status"])
        #expect(result.status == 10)
        #expect(result.out.hasPrefix("paused:"))
        #expect(result.out.contains("Fable"))
    }

    @Test func statusWithNoStateFileIsUnknownRatherThanGo() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["status"])
        #expect(result.status == 3)
        #expect(result.out.contains("no state file"))
    }

    @Test func aWindowSelectorNarrowsWhatCounts() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["gate", "--cap", "85", "--window", "5h"])
        #expect(result.status == 0)
        #expect(result.out.contains("GO"))
        #expect(box.stateText.contains("\"status\": \"go\""))
    }

    /// A selector that matches nothing must not read as "nothing to worry
    /// about" — that failure is silent and lasts all night.
    @Test func aWindowSelectorThatMatchesNothingIsAnError() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["gate", "--window", "fabel"])
        #expect(result.status == 1)
        #expect(result.out.contains("matches no window"))
        #expect(result.out.contains("Fable"))   // names what it could have meant
    }

    // MARK: - Pacer not running

    /// Pacer's API is opt-in. "Off" means no signal, never "no budget" — a
    /// skill that blocked here would break every machine without Pacer.
    @Test func anUnreachableAPINeverBlocksTheRun() throws {
        // One attempt, not the usual three: the retries exist for a server
        // that is restarting, and there is nothing here to come back.
        let box = try Sandbox(metrics: nil)
        let gate = try run(box, ["gate", "--retries", "1"])
        #expect(gate.status == 2)
        #expect(gate.out.contains("proceeding ungated"))

        let report = try run(box, ["report", "--retries", "1"])
        #expect(report.status == 2)
        #expect(report.out.contains("unreachable"))
    }

    /// A window at 0% with no reset time is real server behaviour just after a
    /// reset, not a bug — it must render rather than crash the parse.
    @Test func aWindowWithNoResetTimeStillReports() throws {
        let box = try Sandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0
        pacer_rate_limit_used_ratio{account="org-work",window="seven_day"} 0.4
        pacer_rate_limit_reset_seconds{account="org-work",window="seven_day"} 3600
        """)
        let result = try run(box, ["report"])
        #expect(result.status == 0)
        #expect(result.out.contains("0% used · resets in ?"))
        #expect(result.out.contains("40% used"))
    }

    /// A token set in Pacer but not in the environment answers 401, which for
    /// a long time was indistinguishable from "Pacer is not running" — so one
    /// typo silently unpaced an entire run. It has its own exit code now.
    @Test func aRejectedTokenIsLoudRatherThanSilentlyUngated() throws {
        let box = try Sandbox(metrics: nil)
        let server = try StubServer(status: 401, body: "Unauthorized\n")
        defer { server.stop() }

        let result = try run(box, ["gate", "--retries", "1"], api: server.base)
        #expect(result.status == 4)
        #expect(result.out.contains("PACE_TOKEN"))
        #expect(!result.out.contains("proceeding ungated"))
    }

    /// A verdict has a shelf life. An orchestrator that died an hour ago left
    /// `go` on disk, and every reader after that is obeying a window that has
    /// since moved.
    @Test func aStaleVerdictReadsAsUnknownNotAsGo() throws {
        let box = try Sandbox(metrics: Self.metrics)
        _ = try run(box, ["gate", "--cap", "85", "--window", "5h"])
        #expect(try run(box, ["status"]).status == 0)

        // Backdate the verdict rather than sleeping: the age is read from the
        // file's own `updatedAt`, so this is the same path a crashed
        // orchestrator's leftovers take an hour later.
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        let rewritten = box.stateText.replacingOccurrences(
            of: #""updatedAt": "[^"]+""#, with: #""updatedAt": "\#(old)"#,
            options: .regularExpression)
        try rewritten.write(to: box.stateURL, atomically: true, encoding: .utf8)

        let stale = try run(box, ["status"])
        #expect(stale.status == 3)
        #expect(stale.out.hasPrefix("stale:"))
    }

    /// Two orchestrations on one machine must not overwrite each other's
    /// verdict — the shared default is a convenience, not a requirement.
    @Test func namedRunsKeepSeparateState() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let home = box.dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // No PACE_STATE: the run name alone has to separate them.
        let paused = try run(box, ["gate", "--cap", "85"], unsetState: true,
                             extra: ["HOME": home.path, "PACE_RUN": "alpha"])
        #expect(paused.status == 10)
        let go = try run(box, ["gate", "--cap", "85", "--window", "5h"], unsetState: true,
                         extra: ["HOME": home.path, "PACE_RUN": "beta"])
        #expect(go.status == 0)

        // Alpha's pause survived beta's go.
        let alpha = try run(box, ["status"], unsetState: true,
                            extra: ["HOME": home.path, "PACE_RUN": "alpha"])
        #expect(alpha.status == 10)
    }

    // MARK: - Which windows bind whom

    /// The point of per-model caps: a Fable window at 95% is not an Opus
    /// agent's problem, and stopping it for one is a pause nobody needed.
    @Test func aPerModelCapDoesNotGateAnotherModelsWork() throws {
        let box = try Sandbox(metrics: Self.metrics)

        // Unqualified, everything binds — the safe reading of "did not say".
        #expect(try run(box, ["gate", "--cap", "85"]).status == 10)

        let opus = try run(box, ["gate", "--cap", "85", "--model", "opus"])
        #expect(opus.status == 0)
        #expect(opus.out.contains("GO"))

        let fable = try run(box, ["gate", "--cap", "85", "--model", "fable"])
        #expect(fable.status == 10)
        #expect(fable.out.contains("Fable"))
    }

    /// Account-wide windows constrain every model, so naming one can never
    /// make the 5h or 7d block stop counting.
    @Test func accountWideWindowsBindEveryModel() throws {
        let box = try Sandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.91
        pacer_rate_limit_used_ratio{account="org-work",window="weekly_scoped|Fable|"} 0.10
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 600
        """)
        let result = try run(box, ["gate", "--cap", "85", "--model", "opus"])
        #expect(result.status == 10)
        #expect(result.out.contains("5h"))
    }

    /// Loose matching, because the same window is called "Fable" by the server
    /// and `claude-fable-5-1` by a caller reading its own model id.
    @Test func modelNamesMatchLoosely() throws {
        let box = try Sandbox(metrics: Self.metrics)
        for name in ["Fable", "fable", "claude-fable-5-1", "Fable 5.1"] {
            #expect(try run(box, ["gate", "--cap", "85", "--model", name]).status == 10,
                    "\(name) should bind the Fable cap")
        }
        for name in ["opus", "claude-opus-5", "Sonnet"] {
            #expect(try run(box, ["gate", "--cap", "85", "--model", name]).status == 0,
                    "\(name) should not bind the Fable cap")
        }
    }

    /// The state file is all a subagent reads, so a verdict gated for one model
    /// must not silently answer for another.
    @Test func aVerdictGatedForAnotherModelIsRefused() throws {
        let box = try Sandbox(metrics: Self.metrics)
        _ = try run(box, ["gate", "--cap", "85", "--model", "opus"])
        #expect(try run(box, ["status", "--model", "opus"]).status == 0)

        let mismatched = try run(box, ["status", "--model", "fable"])
        #expect(mismatched.status == 3)
        #expect(mismatched.out.contains("re-gate"))
    }

    // MARK: - Gating on the forecast

    /// 40% is nowhere near any cap, but it is climbing fast enough to run out
    /// inside the hour the wave will take.
    @Test func etaGatingTripsBeforeTheCapDoes() throws {
        let box = try Sandbox(metrics: Self.metrics)
        #expect(try run(box, ["gate", "--cap", "85", "--model", "opus"]).status == 0)

        let horizon = try run(box, ["gate", "--cap", "85", "--model", "opus", "--eta", "90m"])
        #expect(horizon.status == 10)
        #expect(horizon.out.contains("projected to fill"))

        // A horizon shorter than the crossing is headroom again.
        #expect(try run(box, ["gate", "--cap", "85", "--model", "opus", "--eta", "10m"]).status == 0)
    }

    @Test func anUnreadableDurationIsAnErrorNotAZero() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["gate", "--eta", "soon"])
        #expect(result.status == 1)
        #expect(result.out.contains("cannot read duration"))
    }

    /// Regression: the row format used tabs, and bash collapses runs of IFS
    /// *whitespace* — so every account-wide window (empty model column) shifted
    /// each later field left by one and 5h reported its reset time as its
    /// percentage: "3501% used".
    @Test func anEmptyColumnDoesNotShiftEveryLaterField() throws {
        let box = try Sandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.35
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 3501
        """)
        let result = try run(box, ["report"])
        #expect(result.out.contains("35% used"))
        #expect(!result.out.contains("3501%"))
    }

    @Test func reportShowsTheBurnRateAndProjectedFill() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["report"])
        #expect(result.out.contains("+24%/h"))
        #expect(result.out.contains("full in 45m"))
    }

    /// Regression: when Pacer has already narrowed the response to one login,
    /// the parser must not narrow it again.
    ///
    /// It did, and the two disagreed the moment they could — the server was
    /// asked for this session's account while the parser fell back to the
    /// *active* one, which after an account switch is a different account.
    /// Every row was filtered out and the skill reported "no rate-limit
    /// windows yet" while staring at a full set of them.
    @Test func anAlreadyScopedResponseIsNotFilteredAgain() throws {
        // What `/metrics?account=org-home` returns: only that account's
        // windows, but the account directory still names the *active* login.
        let box = try Sandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.29
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 16200
        pacer_account_info{account="org-work",name="w",active="true"} 1
        pacer_account_info{account="org-home",name="h",active="false"} 1
        """)
        let result = try run(box, ["report", "--account", "org-home"])
        #expect(result.status == 0)
        #expect(result.out.contains("29% used"))
    }

    // MARK: - Waiting

    /// Under sequential accounts, headroom usually comes back because someone
    /// switched logins, not because a window reset — and a waiter that says
    /// "reset" either way is telling the operator something false about where
    /// their budget went.
    @Test func waitSaysWhenHeadroomCameFromAnAccountSwitch() throws {
        let box = try Sandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.97
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 900
        pacer_account_info{account="org-work",name="w",active="true"} 1
        """)
        // First poll trips; then the "switch" lands before the next one.
        let switched = """
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.04
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 3600
        pacer_account_info{account="org-home",name="h",active="true"} 1
        """
        let flip = Process()
        flip.executableURL = URL(fileURLWithPath: "/bin/bash")
        flip.arguments = ["-c", "sleep 1; cat > '\(box.dir.path)/metrics'"]
        let input = Pipe()
        flip.standardInput = input
        try flip.run()
        input.fileHandleForWriting.write(Data(switched.utf8))
        try input.fileHandleForWriting.close()

        let result = try run(box, ["wait", "--cap", "85", "--interval", "5"])
        flip.waitUntilExit()
        #expect(result.status == 0)
        #expect(result.out.contains("account switched"))
        #expect(box.stateText.contains("account switched"))
    }

    // MARK: - Knowing what you are

    /// `--model auto` asks Pacer what this session is running, using the
    /// session id Claude Code exports into every command it runs.
    @Test func modelAutoResolvesThroughTheSessionEndpoint() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let server = try StubServer(status: 200, body: """
        {
          "accountId" : "org-work",
          "model" : "claude-opus-5",
          "sessionId" : "abc-123"
        }
        """)
        defer { server.stop() }

        // Metrics come from the fixture; only the session lookup is stubbed,
        // so this exercises the real resolve-then-gate path.
        let result = try run(box, ["gate", "--cap", "85", "--model", "auto"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123",
                                     "PACE_SESSION_API": server.base])
        #expect(result.status == 0)          // Fable at 95% does not bind Opus
        #expect(result.out.contains("GO"))
    }

    /// Which account you are is not a function of which model you run.
    ///
    /// These were one step, and the coupling shipped a dangerous reading: an
    /// orchestrator passing `--model opus` got no session lookup, so the
    /// parser fell back to whichever login was *active* — the idle one — and
    /// reported GO at 0% of a 5-hour window while the account the session
    /// actually ran on sat at 65% with five sessions on it. Work was
    /// dispatched on that.
    @Test func theSessionsAccountIsResolvedEvenWithAnExplicitModel() throws {
        // Two accounts. `pacer_account_info` says org-work is the active
        // login, but this session belongs to org-home — the shape a switcher
        // produces, and the one that made the fallback wrong.
        let box = try Sandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.0
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.65
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 4800
        pacer_account_info{account="org-work",name="w",active="true"} 1
        pacer_account_info{account="org-home",name="h",active="false"} 1
        """)
        let server = try StubServer(status: 200, body: """
        {
          "accountId" : "org-home",
          "model" : "claude-opus-5",
          "sessionId" : "abc-123"
        }
        """)
        defer { server.stop() }

        let result = try run(box, ["report", "--model", "opus"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123",
                                     "PACE_SESSION_API": server.base])
        #expect(result.status == 0)
        #expect(result.out.contains("65% used"))
        // Not the idle login's empty window.
        #expect(!result.out.contains("0% used"))
    }

    /// When several accounts are signed in and the session cannot be
    /// identified, a percentage without an owner is the thing that misleads.
    @Test func anUnidentifiedSessionSaysWhoseNumbersTheseAre() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let result = try run(box, ["gate", "--cap", "99"],
                             extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(result.status == 0)
        #expect(result.out.contains("could not be identified"))
        #expect(result.out.contains("may not be the ones billing you"))
    }

    /// One account, nothing to get wrong, no caveat to add.
    @Test func aSingleAccountNeedsNoCaveat() throws {
        let box = try Sandbox(metrics: """
        pacer_rate_limit_used_ratio{account="solo",window="five_hour"} 0.20
        pacer_rate_limit_reset_seconds{account="solo",window="five_hour"} 3600
        """)
        let result = try run(box, ["gate", "--cap", "85"])
        #expect(result.status == 0)
        #expect(!result.out.contains("could not be identified"))
    }

    /// A session Pacer has not parsed a turn from yet answers 404, and the
    /// safe reading of "cannot tell" is that every window binds.
    @Test func anUnresolvableSessionFallsBackToEveryWindowBinding() throws {
        let box = try Sandbox(metrics: Self.metrics)
        let server = try StubServer(status: 404, body: "No turns recorded\n")
        defer { server.stop() }

        let result = try run(box, ["gate", "--cap", "85", "--model", "auto"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "unknown",
                                     "PACE_SESSION_API": server.base])
        #expect(result.status == 10)
        #expect(result.out.contains("Fable"))
    }

    /// A single-account install emits no `pacer_account_info`, so the script
    /// has to fall back to "the only account there is".
    @Test func aSingleAccountNeedsNoActiveMarker() throws {
        let box = try Sandbox(metrics: """
        pacer_rate_limit_used_ratio{account="solo",window="five_hour"} 0.66
        pacer_rate_limit_reset_seconds{account="solo",window="five_hour"} 1800
        """)
        let result = try run(box, ["report"])
        #expect(result.status == 0)
        #expect(result.out.contains("66% used"))
    }
}
