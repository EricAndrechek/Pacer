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

    private func run(_ sandbox: Sandbox, _ args: [String]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.scriptPath] + args
        var env = ProcessInfo.processInfo.environment
        env["PACER_API"] = "file://\(sandbox.dir.path)"
        env["PACE_STATE"] = sandbox.stateURL.path
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
        let box = try Sandbox(metrics: nil)
        let gate = try run(box, ["gate"])
        #expect(gate.status == 2)
        #expect(gate.out.contains("proceeding ungated"))

        let report = try run(box, ["report"])
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
