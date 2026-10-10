import Foundation
import Testing
@testable import PacerPace

/// `PaceScriptTests` (the executable spec of `pace.sh`), case for case, run
/// against the Swift port. Fixtures and expectations are the script's; the
/// only change is that `wait` cases move the world from the injected sleep
/// instead of from a background process racing a real clock.
@Suite("pace: the pace.sh contract")
struct PaceCommandTests {

    private static let metrics = PaceFixtures.metrics

    // MARK: - Reporting

    @Test func reportListsEveryWindowOfTheActiveAccount() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["report"])
        #expect(result.status == 0)
        #expect(result.out.contains("5h"))
        #expect(result.out.contains("7d"))
        #expect(result.out.contains("Fable"))
        #expect(result.out.contains("95% used"))
        #expect(result.out.contains("resets in 1h 40m"))
        #expect(!result.out.contains("88% used"))
    }

    @Test func anotherAccountIsReadableByName() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["report", "--account", "org-home"])
        #expect(result.status == 0)
        #expect(result.out.contains("88% used"))
        #expect(!result.out.contains("Fable"))
    }

    @Test func jsonCarriesTheFullIdentityAlongsideTheLabel() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["json"])
        #expect(result.status == 0)
        #expect(result.out.contains("\"identity\": \"weekly_scoped|Fable|\""))
        #expect(result.out.contains("\"label\": \"Fable\""))
        #expect(result.out.contains("\"usedPercent\": 95"))
    }

    // MARK: - Gating

    @Test func gateTripsOnAScopedWindowTheFixedBlocksCannotSee() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["gate", "--cap", "85"])
        #expect(result.status == 10)
        #expect(result.out.contains("PAUSE"))
        #expect(result.out.contains("Fable"))
        #expect(box.stateText.contains("\"status\": \"paused\""))
        #expect(box.stateText.contains("\"tripWindow\": \"Fable\""))
    }

    @Test func statusIsAPlainFileReadOfWhatTheGateDecided() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85"])
        try FileManager.default.removeItem(at: box.metricsURL)
        let result = runPace(box, ["status"])
        #expect(result.status == 10)
        #expect(result.out.hasPrefix("paused:"))
        #expect(result.out.contains("Fable"))
    }

    @Test func statusWithNoStateFileIsUnknownRatherThanGo() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["status"])
        #expect(result.status == 3)
        #expect(result.out.contains("no state file"))
    }

    @Test func aWindowSelectorNarrowsWhatCounts() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["gate", "--cap", "85", "--window", "5h"])
        #expect(result.status == 0)
        #expect(result.out.contains("GO"))
        #expect(box.stateText.contains("\"status\": \"go\""))
    }

    @Test func aWindowSelectorThatMatchesNothingIsAnError() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["gate", "--window", "fabel"])
        #expect(result.status == 1)
        #expect(result.out.contains("matches no window"))
        #expect(result.out.contains("Fable"))
    }

    // MARK: - Pacer not running

    @Test func anUnreachableAPINeverBlocksTheRun() throws {
        let box = try PaceSandbox(metrics: nil)
        let gate = runPace(box, ["gate", "--retries", "1"])
        #expect(gate.status == 2)
        #expect(gate.out.contains("proceeding ungated"))
        let report = runPace(box, ["report", "--retries", "1"])
        #expect(report.status == 2)
        #expect(report.out.contains("unreachable"))
    }

    @Test func aWindowWithNoResetTimeStillReports() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0
        pacer_rate_limit_used_ratio{account="org-work",window="seven_day"} 0.4
        pacer_rate_limit_reset_seconds{account="org-work",window="seven_day"} 3600
        """)
        let result = runPace(box, ["report"])
        #expect(result.status == 0)
        #expect(result.out.contains("0% used · resets in ?"))
        #expect(result.out.contains("40% used"))
    }

    @Test func aRejectedTokenIsLoudRatherThanSilentlyUngated() throws {
        let box = try PaceSandbox(metrics: nil)
        let server = try PaceStubServer(status: 401, body: "Unauthorized\n")
        defer { server.stop() }
        let result = runPace(box, ["gate", "--retries", "1"], api: server.base)
        #expect(result.status == 4)
        #expect(result.out.contains("PACE_TOKEN"))
        #expect(!result.out.contains("proceeding ungated"))
    }

    @Test func anAccountPrefixKeepsThatAccountsRows() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="74598a77-37aa",window="five_hour"} 0.71
        pacer_rate_limit_reset_seconds{account="74598a77-37aa",window="five_hour"} 3600
        pacer_rate_limit_used_ratio{account="e34c1364-fc39",window="five_hour"} 0.41
        pacer_rate_limit_reset_seconds{account="e34c1364-fc39",window="five_hour"} 3600
        pacer_account_info{account="e34c1364-fc39",name="w",active="true"} 1
        pacer_account_info{account="74598a77-37aa",name="h",active="false"} 1
        """)
        let result = runPace(box, ["report", "--account", "74598a77"],
                             extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(result.status == 0)
        #expect(result.out.contains("71% used"))
        #expect(!result.out.contains("41% used"))
    }

    // MARK: - The safe limit (no --cap)

    @Test func heavyBurnStopsAtTheSafeLimit() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org",window="five_hour"} 0.92
        pacer_rate_limit_reset_seconds{account="org",window="five_hour"} 3600
        pacer_rate_limit_recent_burn_percent_per_hour{account="org",window="five_hour"} 60
        pacer_rate_limit_sample_age_seconds{account="org",window="five_hour"} 300
        pacer_account_info{account="org",name="o",active="true"} 1
        """)
        let result = runPace(box, ["gate"], extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(result.status == 10)
        #expect(result.out.contains("safe limit 90%"))
        #expect(box.stateText.contains("\"cap\": \"safe\""))
    }

    @Test func lightBurnRunsToNearTheLimit() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org",window="five_hour"} 0.95
        pacer_rate_limit_reset_seconds{account="org",window="five_hour"} 3600
        pacer_rate_limit_recent_burn_percent_per_hour{account="org",window="five_hour"} 3
        pacer_rate_limit_sample_age_seconds{account="org",window="five_hour"} 60
        pacer_account_info{account="org",name="o",active="true"} 1
        """)
        let result = runPace(box, ["gate"], extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(result.status == 0)
        #expect(result.out.contains("safe limit 5h 99%"))
    }

    @Test func withoutABurnTheLimitIs98AndCapStillWins() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org",window="five_hour"} 0.985
        pacer_rate_limit_reset_seconds{account="org",window="five_hour"} 3600
        pacer_account_info{account="org",name="o",active="true"} 1
        """)
        let safe = runPace(box, ["gate"], extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(safe.status == 10)
        #expect(safe.out.contains("safe limit 98%"))
        let json = runPace(box, ["json"], extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(json.out.contains("\"safeLimit\": 98"))
        let capped = runPace(box, ["gate", "--cap", "99.5"], extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(capped.status == 0)
        #expect(capped.out.contains("cap 99.5%"))
    }

    @Test func aRejectedRequestSaysWhatWasRejected() throws {
        let box = try PaceSandbox(metrics: nil)
        let server = try PaceStubServer(status: 400,
                                        body: "Unknown account zzzz. Known: org-home, org-work\n")
        defer { server.stop() }
        let result = runPace(box, ["gate", "--retries", "1", "--account", "zzzz"], api: server.base)
        #expect(result.status == 4)
        #expect(result.out.contains("Unknown account"))
        #expect(!result.out.contains("proceeding ungated"))
    }

    @Test func aStaleVerdictReadsAsUnknownNotAsGo() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--window", "5h"])
        #expect(runPace(box, ["status"]).status == 0)
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        let rewritten = box.stateText.replacingOccurrences(
            of: #""updatedAt": "[^"]+""#, with: #""updatedAt": "\#(old)""#,
            options: .regularExpression)
        try rewritten.write(to: box.stateURL, atomically: true, encoding: .utf8)
        let stale = runPace(box, ["status"])
        #expect(stale.status == 3)
        #expect(stale.out.hasPrefix("stale:"))
    }

    @Test func aWindowWhoseResetIsDueDoesNotPause() throws {
        let box = try PaceSandbox(metrics: """
            pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.85
            pacer_rate_limit_used_ratio{account="org-work",window="seven_day"} 0.10
            pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 0
            pacer_rate_limit_reset_seconds{account="org-work",window="seven_day"} 300000
            pacer_account_info{account="org-work",name="Account work",active="true"} 1
            pacer_up 1
            """)
        let result = runPace(box, ["gate", "--cap", "85"])
        #expect(result.status == 0, "\(result.out)")
        #expect(box.stateText.contains("\"status\": \"go\""))
    }

    @Test func aPauseExpiresWhenItsWindowResets() throws {
        let box = try PaceSandbox(metrics: """
            pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.90
            pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 300
            pacer_account_info{account="org-work",name="Account work",active="true"} 1
            pacer_up 1
            """)
        #expect(runPace(box, ["gate", "--cap", "85"]).status == 10)
        #expect(runPace(box, ["status"]).status == 10)
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-301))
        let rewritten = box.stateText.replacingOccurrences(
            of: #""updatedAt": "[^"]+""#, with: #""updatedAt": "\#(later)""#,
            options: .regularExpression)
        try rewritten.write(to: box.stateURL, atomically: true, encoding: .utf8)
        let expired = runPace(box, ["status"])
        #expect(expired.status == 3)
        #expect(expired.out.hasPrefix("stale:"), "\(expired.out)")
        #expect(expired.out.contains("5h"))
    }

    @Test func namedRunsKeepSeparateState() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let home = box.dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paused = runPace(box, ["gate", "--cap", "85"], unsetState: true,
                             extra: ["HOME": home.path, "PACE_RUN": "alpha"])
        #expect(paused.status == 10)
        let go = runPace(box, ["gate", "--cap", "85", "--window", "5h"], unsetState: true,
                         extra: ["HOME": home.path, "PACE_RUN": "beta"])
        #expect(go.status == 0)
        let alpha = runPace(box, ["status"], unsetState: true,
                            extra: ["HOME": home.path, "PACE_RUN": "alpha"])
        #expect(alpha.status == 10)
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/pace/state-alpha.json").path))
    }

    // MARK: - Which windows bind whom

    @Test func aPerModelCapDoesNotGateAnotherModelsWork() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        #expect(runPace(box, ["gate", "--cap", "85"]).status == 10)
        let opus = runPace(box, ["gate", "--cap", "85", "--model", "opus"])
        #expect(opus.status == 0)
        #expect(opus.out.contains("GO"))
        let fable = runPace(box, ["gate", "--cap", "85", "--model", "fable"])
        #expect(fable.status == 10)
        #expect(fable.out.contains("Fable"))
    }

    @Test func accountWideWindowsBindEveryModel() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.91
        pacer_rate_limit_used_ratio{account="org-work",window="weekly_scoped|Fable|"} 0.10
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 600
        """)
        let result = runPace(box, ["gate", "--cap", "85", "--model", "opus"])
        #expect(result.status == 10)
        #expect(result.out.contains("5h"))
    }

    @Test func modelNamesMatchLoosely() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        for name in ["Fable", "fable", "claude-fable-5-1", "Fable 5.1"] {
            #expect(runPace(box, ["gate", "--cap", "85", "--model", name]).status == 10,
                    "\(name) should bind the Fable cap")
        }
        for name in ["opus", "claude-opus-5", "Sonnet"] {
            #expect(runPace(box, ["gate", "--cap", "85", "--model", name]).status == 0,
                    "\(name) should not bind the Fable cap")
        }
    }

    @Test func aVerdictGatedForAnotherModelIsRefused() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--model", "opus"])
        #expect(runPace(box, ["status", "--model", "opus"]).status == 0)
        let mismatched = runPace(box, ["status", "--model", "fable"])
        #expect(mismatched.status == 3)
        #expect(mismatched.out.contains("re-gate"))
    }

    // MARK: - Gating on the forecast

    @Test func etaGatingTripsBeforeTheCapDoes() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        #expect(runPace(box, ["gate", "--cap", "85", "--model", "opus"]).status == 0)
        let horizon = runPace(box, ["gate", "--cap", "85", "--model", "opus", "--eta", "90m"])
        #expect(horizon.status == 10)
        #expect(horizon.out.contains("projected to fill"))
        #expect(runPace(box, ["gate", "--cap", "85", "--model", "opus", "--eta", "10m"]).status == 0)
    }

    @Test func anUnreadableDurationIsAnErrorNotAZero() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["gate", "--eta", "soon"])
        #expect(result.status == 1)
        #expect(result.out.contains("cannot read duration"))
    }

    @Test func anEmptyColumnDoesNotShiftEveryLaterField() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.35
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 3501
        """)
        let result = runPace(box, ["report"])
        #expect(result.out.contains("35% used"))
        #expect(!result.out.contains("3501%"))
    }

    @Test func reportShowsTheBurnRateAndProjectedFill() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["report"])
        #expect(result.out.contains("+24%/h"))
        #expect(result.out.contains("full in 45m"))
    }

    @Test func anAlreadyScopedResponseIsNotFilteredAgain() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.29
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 16200
        pacer_account_info{account="org-work",name="w",active="true"} 1
        pacer_account_info{account="org-home",name="h",active="false"} 1
        """)
        let result = runPace(box, ["report", "--account", "org-home"])
        #expect(result.status == 0)
        #expect(result.out.contains("29% used"))
    }

    // MARK: - Waiting

    @Test func waitSaysWhenHeadroomCameFromAnAccountSwitch() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.97
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 900
        pacer_account_info{account="org-work",name="w",active="true"} 1
        """)
        let result = runPace(box, ["wait", "--cap", "85", "--interval", "5"], onSleep: { n in
            guard n == 1 else { return }
            try? box.setMetrics("""
            pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.04
            pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 3600
            pacer_account_info{account="org-home",name="h",active="true"} 1
            """)
        })
        #expect(result.status == 0)
        #expect(result.out.contains("account switched"))
        #expect(box.stateText.contains("account switched"))
    }

    @Test func waitFollowsTheSessionToTheNewLogin() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.97
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 900
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.04
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 3600
        pacer_account_info{account="org-work",name="w",active="true"} 1
        pacer_account_info{account="org-home",name="h",active="false"} 1
        """)
        let session = box.dir.appendingPathComponent("session.json")
        func answer(current: String) throws {
            try """
            {
              "accountId" : "org-work",
              "currentAccountId" : "\(current)",
              "sessionId" : "abc-123"
            }
            """.write(to: session, atomically: true, encoding: .utf8)
        }
        try answer(current: "org-work")
        let server = try PaceStubServer(status: 200, body: "", file: session)
        defer { server.stop() }
        let result = runPace(box, ["wait", "--cap", "85", "--interval", "2"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123",
                                     "PACE_SESSION_API": server.base],
                             onSleep: { n in if n == 1 { try? answer(current: "org-home") } })
        #expect(result.status == 0)
        #expect(result.out.contains("account switched"))
    }

    @Test func jsonSaysWhoseWindowsAndSinceWhen() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.42
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 3600
        pacer_account_info{account="org-home",name="h",active="true"} 1
        """)
        let server = try PaceStubServer(status: 200, body: """
        {
          "accountId" : "org-work",
          "currentAccountId" : "org-home",
          "currentAccountSince" : "2026-10-07T00:07:30Z",
          "sessionId" : "abc-123"
        }
        """)
        defer { server.stop() }
        let result = runPace(box, ["json"], extra: ["CLAUDE_CODE_SESSION_ID": "abc-123",
                                                    "PACE_SESSION_API": server.base])
        #expect(result.status == 0)
        #expect(result.out.contains("\"account\": \"org-home\""))
        #expect(result.out.contains("\"accountSince\": \"2026-10-07T00:07:30Z\""))
        let json = try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any]
        #expect(json?["ok"] as? Bool == true)
    }

    @Test func waitKeepsAnExplicitAccount() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.97
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 900
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.04
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 3600
        pacer_account_info{account="org-home",name="h",active="true"} 1
        """)
        let server = try PaceStubServer(status: 200, body: """
        {
          "accountId" : "org-home",
          "currentAccountId" : "org-home",
          "sessionId" : "abc-123"
        }
        """)
        defer { server.stop() }
        let result = runPace(box, ["wait", "--account", "org-work", "--cap", "85", "--max-wait", "60"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123",
                                     "PACE_SESSION_API": server.base])
        #expect(result.status == 20)
        #expect(!result.out.contains("account switched"))
    }

    @Test func waitHoldsThePauseWhilePacerIsRestarting() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.97
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} 600
        """)
        // Away for two polls, then back with headroom: a restart, not a reset.
        let result = runPace(box, ["wait", "--cap", "85", "--interval", "5", "--retries", "1"],
                             onSleep: { n in
            if n == 1 { try? FileManager.default.removeItem(at: box.metricsURL) }
            if n == 3 {
                try? box.setMetrics("pacer_rate_limit_used_ratio{account=\"org-work\",window=\"five_hour\"} 0.04\n")
            }
        })
        #expect(result.status == 0)
        #expect(result.out.contains("holding the pause"))
        #expect(!result.out.contains("proceeding ungated"))
    }

    // MARK: - Knowing what you are

    private func sessionStub(_ models: [String]) throws -> PaceStubServer {
        let list = models.map { "\"\($0)\"" }.joined(separator: ", ")
        return try PaceStubServer(status: 200, body: """
        {
          "accountId" : "org-work",
          "model" : "\(models.first ?? "")",
          "models" : [\(list)],
          "sessionId" : "abc-123"
        }
        """)
    }

    @Test func aFanOutDoesNotGateBuildersOnTheOrchestratorsCap() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try sessionStub(["claude-fable-5-1", "claude-sonnet-5"])
        defer { server.stop() }
        let result = runPace(box, ["gate", "--cap", "85", "--model", "auto"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base])
        #expect(result.status == 0)
        #expect(result.out.contains("GO"))
        #expect(result.out.contains("ambiguous"))
        #expect(!box.stateText.contains("\"tripWindow\": \"Fable\""))
    }

    @Test func oneModelInFlightStillGatesOnItsOwnCap() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try sessionStub(["claude-fable-5-1"])
        defer { server.stop() }
        let result = runPace(box, ["gate", "--cap", "85", "--model", "auto"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base])
        #expect(result.status == 10)
        #expect(result.out.contains("PAUSE"))
        #expect(result.out.contains("Fable"))
    }

    @Test func autoSaysWhichModelItResolved() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try sessionStub(["claude-fable-5-1"])
        defer { server.stop() }
        let result = runPace(box, ["report", "--model", "auto"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base])
        #expect(result.status == 0)
        #expect(result.out.contains("detected"))
        #expect(result.out.contains("claude-fable-5-1"))
    }

    @Test func anUnknownIdentityBindsOnlyAccountWideWindows() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["gate", "--cap", "85"], extra: ["PACE_MODEL": "__ambiguous__"])
        #expect(result.status == 0)
        #expect(result.out.contains("GO"))
        let listing = runPace(box, ["report"], extra: ["PACE_MODEL": "__ambiguous__"])
        #expect(listing.out.contains("binds Fable only"))
    }

    @Test func modelAutoResolvesThroughTheSessionEndpoint() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try PaceStubServer(status: 200, body: """
        {
          "accountId" : "org-work",
          "model" : "claude-opus-5",
          "sessionId" : "abc-123"
        }
        """)
        defer { server.stop() }
        let result = runPace(box, ["gate", "--cap", "85", "--model", "auto"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base])
        #expect(result.status == 0)
        #expect(result.out.contains("GO"))
    }

    @Test func theSessionsAccountIsResolvedEvenWithAnExplicitModel() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} 0.0
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.65
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 4800
        pacer_account_info{account="org-work",name="w",active="true"} 1
        pacer_account_info{account="org-home",name="h",active="false"} 1
        """)
        let server = try PaceStubServer(status: 200, body: """
        {
          "accountId" : "org-home",
          "model" : "claude-opus-5",
          "sessionId" : "abc-123"
        }
        """)
        defer { server.stop() }
        let result = runPace(box, ["report", "--model", "opus"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base])
        #expect(result.status == 0)
        #expect(result.out.contains("65% used"))
        #expect(!result.out.contains("0% used"))
    }

    @Test func anUnidentifiedSessionSaysWhoseNumbersTheseAre() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["gate", "--cap", "99"], extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(result.status == 0)
        #expect(result.out.contains("could not be identified"))
        #expect(result.out.contains("may not be the ones billing you"))
    }

    @Test func aSingleAccountNeedsNoCaveat() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="solo",window="five_hour"} 0.20
        pacer_rate_limit_reset_seconds{account="solo",window="five_hour"} 3600
        """)
        let result = runPace(box, ["gate", "--cap", "85"])
        #expect(result.status == 0)
        #expect(!result.out.contains("could not be identified"))
    }

    @Test func anUnresolvableSessionFallsBackToEveryWindowBinding() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try PaceStubServer(status: 404, body: "No turns recorded\n")
        defer { server.stop() }
        let result = runPace(box, ["gate", "--cap", "85", "--model", "auto"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "unknown", "PACE_SESSION_API": server.base])
        #expect(result.status == 10)
        #expect(result.out.contains("Fable"))
    }

    @Test func aSingleAccountNeedsNoActiveMarker() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="solo",window="five_hour"} 0.66
        pacer_rate_limit_reset_seconds{account="solo",window="five_hour"} 1800
        """)
        let result = runPace(box, ["report"])
        #expect(result.status == 0)
        #expect(result.out.contains("66% used"))
    }
}
