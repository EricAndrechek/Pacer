import Foundation
import Testing
@testable import PacerPace

/// The executable spec of `pace.sh` (once `PaceScriptTests`, run against the
/// bash script), case for case, now the spec of `pacer`. Fixtures and
/// expectations are the script's; the only change is that `wait` cases move
/// the world from the injected sleep instead of from a background process
/// racing a real clock.
@Suite("pace: the contract pace.sh had")
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
        let result = runPace(box, ["status", "--no-refresh"])
        #expect(result.status == 3)
        #expect(result.out.contains("no state file"))
        // With no Pacer to re-gate from, still unknown rather than go.
        let off = try PaceSandbox(metrics: nil)
        let unread = runPace(off, ["status", "--retries", "1"])
        #expect(unread.status == 3, "\(unread.out)")
        #expect(unread.out.contains("unknown"))
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
        // Was "unreachable": exit 2 now means no Pacer at all, since the
        // command line reads Pacer's data when the API is off (#194).
        #expect(report.out.contains("no Pacer to read"))
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
        let stale = runPace(box, ["status", "--no-refresh"])
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
        let expired = runPace(box, ["status", "--no-refresh"])
        #expect(expired.status == 3)
        #expect(expired.out.hasPrefix("stale:"), "\(expired.out)")
        #expect(expired.out.contains("5h"))
        // Re-gated, by the pause's own --cap 85, against a window still at 90%.
        let regated = runPace(box, ["status"])
        #expect(regated.status == 10, "\(regated.out)")
        #expect(regated.out.contains("the 5h pause had expired — re-gated"), "\(regated.out)")
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

    // MARK: - status re-gates a stale verdict, once for every reader (#266)

    @Test func aStaleVerdictIsReGatedByItsOwnSettings() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        #expect(runPace(box, ["gate", "--cap", "85", "--window", "5h", "--model", "opus"]).status == 0)
        try age(box, by: 7200)
        // The 5h window has climbed past the gate's own cap since.
        try box.setMetrics(Self.metrics.replacingOccurrences(
            of: "window=\"five_hour\"} 0.12", with: "window=\"five_hour\"} 0.90"))
        let log = PaceRequestLog()
        let result = runPace(box, ["status"], onGet: log.record)
        #expect(result.status == 10, "\(result.out)")
        #expect(result.out.contains("paused: 5h at 90% >= cap 85%"), "\(result.out)")
        #expect(result.out.contains("the verdict was 120m old — re-gated"))
        #expect(log.count("metrics") == 1)
        #expect(box.stateText.contains("\"cap\": 85"))
        #expect(box.stateText.contains("\"window\": \"5h\""))
        #expect(box.stateText.contains("\"model\": \"opus\""))
        // Fresh now: the next reader reads the file and nothing else.
        let next = PaceRequestLog()
        #expect(runPace(box, ["status"], onGet: next.record).status == 10)
        #expect(next.all.isEmpty)
    }

    @Test func noRefreshIsThePureFileRead() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--window", "5h"])
        try age(box, by: 7200)
        let before = box.stateText
        let log = PaceRequestLog()
        let result = runPace(box, ["status", "--no-refresh"], onGet: log.record)
        #expect(result.status == 3)
        #expect(result.out.hasPrefix("stale:"))
        #expect(log.all.isEmpty)
        #expect(box.stateText == before)
    }

    @Test func aMissingVerdictIsGatedOnFirstRead() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["status"])
        #expect(result.status == 0, "\(result.out)")
        #expect(result.out.contains("\ngo (until "), "\(result.out)")
        #expect(result.out.contains("no verdict yet — re-gated"))
        #expect(box.stateText.contains("\"status\": \"go\""))
    }

    @Test func aStaleVerdictForAnotherModelIsNotReGated() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--model", "opus"])
        try age(box, by: 7200)
        let log = PaceRequestLog()
        let result = runPace(box, ["status", "--model", "fable"], onGet: log.record)
        #expect(result.status == 3)
        #expect(result.out.hasPrefix("stale:"))
        #expect(log.all.isEmpty, "re-gating opus's verdict cannot answer fable")
    }

    @Test func statusAsksPacerNothingWhileTheVerdictIsFresh() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--window", "5h"])
        let log = PaceRequestLog()
        // A session id used to cost a /v1/session lookup on every status.
        let result = runPace(box, ["status"], extra: ["CLAUDE_CODE_SESSION_ID": "abc-123"], onGet: log.record)
        #expect(result.status == 0)
        #expect(log.all.isEmpty, "\(log.all)")
    }

    @Test func aReGateThatCannotReadPacerIsReadOnce() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--window", "5h"])
        try age(box, by: 7200)
        try FileManager.default.removeItem(at: box.metricsURL)
        let log = PaceRequestLog()
        let first = runPace(box, ["status", "--retries", "1"], onGet: log.record)
        #expect(first.status == 3)
        #expect(first.out.contains("unknown"), "\(first.out)")
        #expect(log.count("metrics") == 1)
        let second = runPace(box, ["status", "--retries", "1"], onGet: log.record)
        #expect(second.status == 3)
        #expect(log.count("metrics") == 1, "a fresh 'unknown' is not re-read until it is stale")
    }

    @Test func manyReadersOfOneStaleVerdictCostOneRead() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--window", "5h"])
        try age(box, by: 7200)
        let log = PaceRequestLog()
        let lanes = 8
        let codes = PaceRequestLog()
        DispatchQueue.concurrentPerform(iterations: lanes) { _ in
            let result = runPace(box, ["status"], onGet: { request in
                log.record(request)
                // A slow read, so the other lanes find the lock held.
                Thread.sleep(forTimeInterval: 0.3)
            })
            codes.record(URLRequest(url: URL(string: "x:/\(result.status)")!))
        }
        #expect(log.count("metrics") == 1, "\(log.all)")
        #expect(codes.all == Array(repeating: "0", count: lanes), "\(codes.all)")
    }

    @Test func aReaderThatLosesTheRaceTakesTheWinnersVerdict() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--window", "5h"])
        try age(box, by: 7200)
        let held = PaceRefreshLock(path: box.stateURL.path + ".lock")
        #expect(held.acquire() == .acquired)
        defer { held.release() }
        let log = PaceRequestLog()
        var naps = 0
        let result = runPace(box, ["status"], onGet: log.record, nap: { _ in
            naps += 1
            // The winner writes its verdict.
            if naps == 2 { try? age(box, by: 0) }
        })
        #expect(result.status == 0, "\(result.out)")
        #expect(result.out.contains("another reader re-gated it"))
        #expect(naps == 2)
        #expect(log.all.isEmpty)
    }

    @Test func aReaderThatLosesTheRaceGivesUpAfterAboutThreeSeconds() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85", "--window", "5h"])
        try age(box, by: 7200)
        let held = PaceRefreshLock(path: box.stateURL.path + ".lock")
        #expect(held.acquire() == .acquired)
        defer { held.release() }
        var napped = 0.0
        let result = runPace(box, ["status"], nap: { napped += $0 })
        #expect(result.status == 3)
        #expect(result.out.hasPrefix("stale:"))
        #expect(abs(napped - 3) < 0.01, "\(napped)")
    }

    // MARK: - One verdict per session by default (#265)

    private func paceHome(_ box: PaceSandbox) throws -> URL {
        let home = box.dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func aSessionGetsItsOwnDefaultStateFile() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let home = try paceHome(box)
        let mine = ["HOME": home.path, "CLAUDE_CODE_SESSION_ID": "0f3c9a12-aaaa-bbbb-cccc-1234567890ab"]
        // A test gate in one session...
        #expect(runPace(box, ["gate", "--cap", "50"], unsetState: true, extra: mine).status == 10)
        let file = home.appendingPathComponent(".claude/pace/state-session-0f3c9a12.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(runPace(box, ["status"], unsetState: true, extra: mine).status == 10)
        // ...pauses nobody else.
        let theirs = ["HOME": home.path, "CLAUDE_CODE_SESSION_ID": "77aa0000-1111"]
        let other = runPace(box, ["status", "--no-refresh"], unsetState: true, extra: theirs)
        #expect(other.status == 3)
        #expect(other.out.contains("state-session-77aa0000.json"), "\(other.out)")
        #expect(runPace(box, ["status"], unsetState: true, extra: theirs).status == 0,
                "their own verdict, gated on first read (#266)")
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/pace/state.json").path))
    }

    @Test func aNamedRunOrPathStillBeatsTheSessionDefault() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let home = try paceHome(box)
        let session = ["HOME": home.path, "CLAUDE_CODE_SESSION_ID": "0f3c9a12-aaaa"]
        var run = session
        run["PACE_RUN"] = "alpha"
        _ = runPace(box, ["gate", "--cap", "85"], unsetState: true, extra: run)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/pace/state-alpha.json").path))
        let named = box.dir.appendingPathComponent("named.json")
        var state = session
        state["PACE_STATE"] = named.path
        _ = runPace(box, ["gate", "--cap", "85"], unsetState: true, extra: state)
        #expect(FileManager.default.fileExists(atPath: named.path))
        let flag = box.dir.appendingPathComponent("flag.json")
        _ = runPace(box, ["gate", "--cap", "85", "--state", flag.path], unsetState: true, extra: session)
        #expect(FileManager.default.fileExists(atPath: flag.path))
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/pace/state-session-0f3c9a12.json").path))
    }

    @Test func withoutASessionTheDefaultIsStillStateJSON() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let home = try paceHome(box)
        _ = runPace(box, ["gate", "--cap", "85"], unsetState: true,
                    extra: ["HOME": home.path, "CLAUDE_CODE_SESSION_ID": ""])
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/pace/state.json").path))
    }

    @Test func aSessionIdIsCutToEightFileNameSafeCharacters() {
        #expect(PaceStateFile.sessionTag("0f3c9a12-aaaa-bbbb") == "0f3c9a12")
        #expect(PaceStateFile.sessionTag("../../etc/passwd") == "etcpassw")
        #expect(PaceStateFile.sessionTag("ab") == "ab")
        #expect(PaceStateFile.sessionTag("") == nil)
        #expect(PaceStateFile.sessionTag("/./") == nil)
        #expect(PaceStateFile.sessionTag(nil) == nil)
    }

    @Test func aGatePrunesOtherSessionsLongStaleDefaults() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let home = try paceHome(box)
        let dir = home.appendingPathComponent(".claude/pace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        let longAgo = Date().addingTimeInterval(-8 * 86_400)
        func file(_ name: String, old: Bool) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try "{}\n".write(to: url, atomically: true, encoding: .utf8)
            if old { try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path) }
            return url
        }
        let gone = try file("state-session-deadbeef.json", old: true)
        let goneLock = try file("state-session-deadbeef.json.lock", old: true)
        let recent = try file("state-session-cafe0001.json", old: false)
        let named = try file("state-alpha.json", old: true)
        let shared = try file("state.json", old: true)
        let manifest = try file("resume-alpha.json", old: true)
        _ = runPace(box, ["gate", "--cap", "85"], unsetState: true,
                    extra: ["HOME": home.path, "CLAUDE_CODE_SESSION_ID": "0f3c9a12-aaaa"])
        #expect(!fm.fileExists(atPath: gone.path))
        #expect(!fm.fileExists(atPath: goneLock.path))
        for kept in [recent, named, shared, manifest] {
            #expect(fm.fileExists(atPath: kept.path), "\(kept.lastPathComponent) is not a stale session default")
        }
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

    /// #258: the skill's protocol is gate, then on PAUSE a bare `wait`. A
    /// gate that paused on its horizon used to be followed by a wait judging
    /// the safe limit alone, which "resumed" at once.
    @Test func aBareWaitKeepsTheHorizonThePauseWasFor() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        #expect(runPace(box, ["gate", "--cap", "85", "--model", "opus", "--eta", "90m"]).status == 10)

        // Still projected to fill inside 90m on the first look; then the
        // projection clears.
        let wait = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            if n == 1 { try? box.setMetrics(Self.metrics.replacingOccurrences(of: "will_hit{", with: "will_hit_old{")) }
        })
        #expect(wait.status == 0)
        #expect(wait.out.contains("waiting by the gate's settings (--cap 85, --eta 1h 30m, --model opus)"), "\(wait.out)")
        #expect(wait.out.contains("projected to fill"), "it waited instead of resuming at once")
    }

    @Test func aWaitsOwnFlagsBeatTheGates() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        #expect(runPace(box, ["gate", "--cap", "85", "--model", "opus", "--eta", "90m"]).status == 10)
        let wait = runPace(box, ["wait", "--cap", "85", "--model", "opus", "--eta", "10m"])
        #expect(wait.status == 0)
        #expect(!wait.out.contains("waiting by the gate's settings"))
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
        // 97% to 4% inside one cycle, with no reset time on the reading: a
        // drop below the pause's 85%, and said as one.
        #expect(result.out.contains("usage fell — 5h at 4%, below the 85% it paused at"), "\(result.out)")
    }

    // MARK: - wait resumes on a reset, a switch or a real drop, nothing else (#267)

    /// 5h at 97% with a burn that puts the safe limit at 97; then the burn
    /// falls as paused sessions stop, and the safe limit rises to 99.
    private static func burning(_ ratio: String = "0.97", burn: String = "36",
                                resets: String = "3600") -> String {
        """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} \(ratio)
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} \(resets)
        pacer_rate_limit_recent_burn_percent_per_hour{account="org-work",window="five_hour"} \(burn)
        pacer_rate_limit_sample_age_seconds{account="org-work",window="five_hour"} 0
        pacer_rate_limit_used_ratio{account="org-work",window="seven_day"} 0.26
        pacer_rate_limit_reset_seconds{account="org-work",window="seven_day"} 300000
        pacer_account_info{account="org-work",name="w",active="true"} 1
        """
    }

    /// The bug, as it happened: a pause at 5h 97% "reset" while still at 97%
    /// because the safe limit rose.
    @Test func aRisingSafeLimitIsNotAReset() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        var polls = 0
        let result = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            polls = n
            if n == 1 { try? box.setMetrics(Self.burning(burn: "12")) }
            // The next cycle: 3%, resetting five hours out.
            if n == 4 { try? box.setMetrics(Self.burning("0.03", burn: "12", resets: "18000")) }
        })
        #expect(result.status == 0, "\(result.out)")
        #expect(polls == 4, "it resumed before the window reset:\n\(result.out)")
        #expect(result.out.contains("5h at 97% >= safe limit 97%"), "\(result.out)")
        #expect(result.out.contains("would pass the limit now (99%), but it paused at 97%"), "\(result.out)")
        #expect(result.out.contains("pace: reset — the 5h window rolled over; headroom restored (5h 3%, 7d 26%). Resume."),
                "\(result.out)")
        #expect(box.stateText.contains("reset — 5h rolled over"))
    }

    @Test func aWaitAfterAGateHoldsTheGatesTrip() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        let gate = runPace(box, ["gate"])
        #expect(gate.status == 10)
        #expect(box.stateText.contains("\"tripIdentity\": \"five_hour\""))
        #expect(box.stateText.contains("\"tripAccount\": \"org-work\""))
        #expect(box.stateText.contains("\"tripLimit\": 97"))
        // Between the gate and the wait, the burn falls: on its own rules the
        // wait would see headroom at its first look and leave at once.
        try box.setMetrics(Self.burning(burn: "12"))
        var polls = 0
        let result = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            polls = n
            if n == 2 { try? box.setMetrics(Self.burning("0.95", burn: "12")) }
        })
        #expect(result.status == 0)
        #expect(polls == 2, "\(result.out)")
        #expect(result.out.contains("pace: usage fell — 5h at 95%, below the 97% it paused at (5h 95%, 7d 26%). Resume."),
                "\(result.out)")
        #expect(!result.out.contains("pace: reset"), "nothing reset:\n\(result.out)")
    }

    @Test func aDueResetEndsThePause() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        let result = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            // Pacer's last reading of the window that just ended.
            if n == 1 { try? box.setMetrics(Self.burning(resets: "-5")) }
        })
        #expect(result.status == 0)
        #expect(result.out.contains("reset — the 5h window rolled over"), "\(result.out)")
    }

    @Test func aSwitchToASpentLoginDoesNotResume() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        var polls = 0
        let result = runPace(box, ["wait", "--cap", "85", "--interval", "5"], onSleep: { n in
            polls = n
            if n == 1 {
                try? box.setMetrics("""
                pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.99
                pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 900
                pacer_account_info{account="org-home",name="h",active="true"} 1
                """)
            }
            if n == 3 {
                try? box.setMetrics("""
                pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} 0.04
                pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} 18000
                pacer_account_info{account="org-home",name="h",active="true"} 1
                """)
            }
        })
        #expect(result.status == 0)
        #expect(polls == 3, "\(result.out)")
        #expect(result.out.contains("account switched (org-work → org-home), but 5h at 99% >= cap 85%"), "\(result.out)")
        #expect(result.out.contains("reset — the 5h window rolled over"), "\(result.out)")
    }

    @Test func aWaitToldOtherRulesIgnoresTheGatesTrip() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        #expect(runPace(box, ["gate"]).status == 10)
        // --cap 99 is this wait's own question, and 97% answers it.
        let result = runPace(box, ["wait", "--cap", "99"])
        #expect(result.status == 0)
        #expect(!result.out.contains("waiting"), "\(result.out)")
    }

    // MARK: - The release rule itself (#267)

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func row(_ percent: Double, resets: String?, willHit: String = "0",
                            hitEta: String? = nil) -> PaceRow {
        PaceRow(account: "org", identity: "five_hour", label: "5h", model: "", percent: percent,
                resetsIn: resets, hitEta: hitEta, burn: nil, willHit: willHit, recentBurn: nil, sampleAge: nil)
    }

    private static func anchored(limit: Double, why: String = "cap", resetsIn: TimeInterval? = 3600) -> PaceRules.Anchor {
        PaceRules.Anchor(
            trip: PaceRules.Trip(label: "5h", percentText: "97", resetsIn: nil, why: why, hitEta: nil,
                                 limit: limit, identity: "five_hour", account: "org"),
            resetsAt: resetsIn.map { t0.addingTimeInterval($0) })
    }

    @Test func releaseHoldsAtTheSameUsageWhateverTheLimitNowIs() {
        let a = Self.anchored(limit: 97)
        #expect(PaceRules.release(a, rows: [Self.row(97, resets: "3500")], now: Self.t0.addingTimeInterval(100), horizon: 0) == nil)
        #expect(PaceRules.release(a, rows: [Self.row(98, resets: "3500")], now: Self.t0.addingTimeInterval(100), horizon: 0) == nil)
    }

    @Test func releaseOnARealDrop() {
        #expect(PaceRules.release(Self.anchored(limit: 97), rows: [Self.row(96.5, resets: "3500")],
                                  now: Self.t0.addingTimeInterval(100), horizon: 0) == .drop)
    }

    @Test func releaseOnAResetByTheClockByADueReadingOrByALaterCycle() {
        let a = Self.anchored(limit: 97)
        #expect(PaceRules.release(a, rows: [Self.row(97, resets: "1")], now: Self.t0.addingTimeInterval(3600), horizon: 0) == .reset)
        #expect(PaceRules.release(a, rows: [Self.row(97, resets: "0")], now: Self.t0.addingTimeInterval(100), horizon: 0) == .reset)
        // The next cycle's reset, five hours after this one's.
        #expect(PaceRules.release(a, rows: [Self.row(97, resets: "21500")], now: Self.t0.addingTimeInterval(100), horizon: 0) == .reset)
    }

    @Test func aJitteringResetInstantIsTheSameCycle() {
        // The server re-serializes resets_at on every response; seconds of
        // drift are the same cycle (AGENTS.md rule 9).
        let a = Self.anchored(limit: 97)
        for resets in ["3497", "3503", "3500.4"] {
            #expect(PaceRules.release(a, rows: [Self.row(97, resets: resets)], now: Self.t0.addingTimeInterval(100), horizon: 0) == nil,
                    "\(resets)")
        }
    }

    @Test func aWindowMissingFromTheReadingHoldsUntilItsReset() {
        let a = Self.anchored(limit: 97)
        #expect(PaceRules.release(a, rows: [], now: Self.t0.addingTimeInterval(100), horizon: 0) == nil)
        #expect(PaceRules.release(a, rows: [], now: Self.t0.addingTimeInterval(3600), horizon: 0) == .reset)
        let other = PaceRow(account: "org-other", identity: "five_hour", label: "5h", model: "", percent: 1,
                            resetsIn: "3500", hitEta: nil, burn: nil, willHit: "0", recentBurn: nil, sampleAge: nil)
        #expect(PaceRules.release(a, rows: [other], now: Self.t0.addingTimeInterval(100), horizon: 0) == nil,
                "another account's window is not this one")
    }

    @Test func aForecastPauseEndsWhenTheForecastClears() {
        let a = Self.anchored(limit: 85, why: "eta")
        let projected = Self.row(40, resets: "3500", willHit: "1", hitEta: "1800")
        #expect(PaceRules.release(a, rows: [projected], now: Self.t0.addingTimeInterval(100), horizon: 5400) == nil)
        let cleared = Self.row(40, resets: "3500", willHit: "0")
        #expect(PaceRules.release(a, rows: [cleared], now: Self.t0.addingTimeInterval(100), horizon: 5400) == .forecast)
        let farOff = Self.row(40, resets: "3500", willHit: "1", hitEta: "9000")
        #expect(PaceRules.release(a, rows: [farOff], now: Self.t0.addingTimeInterval(100), horizon: 5400) == .forecast)
    }

    @Test func cycleLengthsByIdentity() {
        #expect(PaceRules.cycleLength(identity: "five_hour") == 18_000)
        #expect(PaceRules.cycleLength(identity: "seven_day") == 604_800)
        #expect(PaceRules.cycleLength(identity: "weekly_scoped|Fable|") == 604_800)
        #expect(PaceRules.cycleLength(identity: "daily|claude-opus-5|web") == 86_400)
        #expect(PaceRules.cycleLength(identity: "something||cli") == 18_000)
    }

    // MARK: - A GO runs out near the limit (#313)

    /// 5h at 88%, climbing 45%/h, read a minute ago: a safe limit of 95, so
    /// 7 points of headroom, which 45%/h uses up in 9 minutes 20 seconds.
    private static func nearing(_ ratio: String = "0.88", burn: String = "45",
                                resets: String = "3600") -> String {
        """
        pacer_rate_limit_used_ratio{account="org-work",window="five_hour"} \(ratio)
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} \(resets)
        pacer_rate_limit_recent_burn_percent_per_hour{account="org-work",window="five_hour"} \(burn)
        pacer_rate_limit_sample_age_seconds{account="org-work",window="five_hour"} 60
        pacer_rate_limit_used_ratio{account="org-work",window="seven_day"} 0.30
        pacer_rate_limit_reset_seconds{account="org-work",window="seven_day"} 300000
        pacer_account_info{account="org-work",name="w",active="true"} 1
        """
    }

    /// Seconds from a verdict's `updatedAt` to its `goUntil`.
    private func goLife(_ box: PaceSandbox) throws -> TimeInterval {
        let state = PaceStateFile(path: box.stateURL.path)
        let until = try #require(state.goUntil, "\(box.stateText)")
        let written = try #require(state.quoted("updatedAt").flatMap(PaceFormat.isoFormatter.date(from:)))
        return until.timeIntervalSince(written)
    }

    /// The issue's numbers: 88% used against a 95% limit at 45%/h is wrong
    /// after about 9.3 minutes, and lanes used to obey it for 15.
    @Test func aGoNearTheLimitRunsOutWhenTheWindowWouldReachIt() throws {
        let box = try PaceSandbox(metrics: Self.nearing())
        let gate = runPace(box, ["gate"])
        #expect(gate.status == 0, "\(gate.out)")
        #expect(gate.out.contains("(safe limit 5h 95%, 7d 98%)"), "\(gate.out)")
        #expect(gate.out.contains("5h reaches its 95% limit in ~9m at 45%/h."), "\(gate.out)")
        let life = try goLife(box)
        #expect(abs(life - 560) <= 1, "\(life)")
        let until = try #require(PaceStateFile(path: box.stateURL.path).goUntil)
        #expect(gate.out.contains("Good until \(PaceFormat.utcClock(until))"), "\(gate.out)")

        // Still good after 9 minutes, and says until when.
        let fresh = runPace(box, ["status", "--no-refresh"], later: 530)
        #expect(fresh.status == 0)
        #expect(fresh.out == "go (until \(PaceFormat.utcClock(until)))\n", "\(fresh.out)")
        // Spent after 10, with 5 minutes of its old shelf life to go.
        let spent = runPace(box, ["status", "--no-refresh"], later: 600)
        #expect(spent.status == 3, "\(spent.out)")
        #expect(spent.out.hasPrefix("stale: the go verdict ran out at \(PaceFormat.utcClock(until))"), "\(spent.out)")
    }

    @Test func aSpentGoIsReGatedOnceForEveryReader() throws {
        let box = try PaceSandbox(metrics: Self.nearing())
        #expect(runPace(box, ["gate"]).status == 0)
        // Ten minutes on, the window is where the projection put it.
        try box.setMetrics(Self.nearing("0.955"))
        let log = PaceRequestLog()
        let result = runPace(box, ["status"], later: 600, onGet: log.record)
        #expect(result.status == 10, "\(result.out)")
        #expect(result.out.contains("the go verdict ran out at"), "\(result.out)")
        #expect(result.out.contains("— re-gated."), "\(result.out)")
        #expect(result.out.contains("paused: 5h at 95.5% >= safe limit 95%"), "\(result.out)")
        #expect(log.count("metrics") == 1)
        #expect(box.stateText.contains("\"goUntil\": null"))
    }

    @Test func withRoomAGoKeepsItsShelfLife() throws {
        let box = try PaceSandbox(metrics: Self.nearing("0.30", burn: "10"))
        let gate = runPace(box, ["gate"])
        #expect(gate.status == 0)
        #expect(!gate.out.contains("Good until"), "the shelf life decides, so the line is as it was:\n\(gate.out)")
        #expect(abs(try goLife(box) - 900) <= 1)
        #expect(runPace(box, ["status", "--no-refresh"], later: 880).status == 0)
        // No burn at all: the shelf life, as before.
        let idle = try PaceSandbox(metrics: Self.nearing("0.30", burn: "").replacingOccurrences(
            of: "pacer_rate_limit_recent_burn_percent_per_hour{account=\"org-work\",window=\"five_hour\"} \n", with: ""))
        #expect(runPace(idle, ["gate", "--max-age", "600"]).status == 0)
        #expect(abs(try goLife(idle) - 600) <= 1)
    }

    @Test func aGoAtTheLimitStillLastsAMinute() throws {
        // A tenth of a point at 45%/h is 8 seconds.
        let box = try PaceSandbox(metrics: Self.nearing("0.949"))
        #expect(runPace(box, ["gate"]).status == 0)
        #expect(abs(try goLife(box) - PaceRules.minimumGoLife) <= 1)
    }

    @Test func aGoUnderAHorizonRunsOutWhenTheFillComesInsideIt() throws {
        let box = try PaceSandbox(metrics: Self.nearing("0.30", burn: "10") + """

        pacer_rate_limit_will_hit{account="org-work",window="five_hour"} 1
        pacer_rate_limit_hit_eta_seconds{account="org-work",window="five_hour"} 3900
        """)
        let gate = runPace(box, ["gate", "--eta", "1h"])
        #expect(gate.status == 0, "\(gate.out)")
        #expect(gate.out.contains("5h is then projected to fill within 1h 0m."), "\(gate.out)")
        #expect(abs(try goLife(box) - 300) <= 1)
    }

    @Test func aWaitsResumeCarriesAnExpiryAndAPauseNone() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        #expect(runPace(box, ["gate"]).status == 10)
        #expect(box.stateText.contains("\"goUntil\": null"))
        let result = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            if n == 1 { try? box.setMetrics(Self.burning("0.03", burn: "12", resets: "18000")) }
        })
        #expect(result.status == 0)
        // 3% to a 99% limit at 12%/h is eight hours: the shelf life decides.
        #expect(abs(try goLife(box) - 900) <= 1)
    }

    @Test func aVerdictWithoutAnExpiryReadsAsItDid() throws {
        let box = try PaceSandbox(metrics: Self.nearing())
        #expect(runPace(box, ["gate"]).status == 0)
        // As a verdict written before there was a `goUntil`.
        try box.stateText.replacingOccurrences(of: #"  "goUntil": "[^"]+",\n"#, with: "", options: .regularExpression)
            .write(to: box.stateURL, atomically: true, encoding: .utf8)
        #expect(!box.stateText.contains("goUntil"))
        let result = runPace(box, ["status", "--no-refresh"], later: 600)
        #expect(result.status == 0)
        #expect(result.out == "go\n")
    }

    private static func window(_ label: String, identity: String, percent: Double, resets: String? = "3600",
                               recent: String? = nil, willHit: String = "0", hitEta: String? = nil) -> PaceRow {
        PaceRow(account: "org", identity: identity, label: label, model: "", percent: percent,
                resetsIn: resets, hitEta: hitEta, burn: nil, willHit: willHit, recentBurn: recent, sampleAge: "0")
    }

    @Test func goExpiryTakesTheSoonestWindowThatGetsThereThisCycle() {
        let fiveHour = Self.window("5h", identity: "five_hour", percent: 80, recent: "30")
        let weekly = Self.window("7d", identity: "seven_day", percent: 97, resets: "300000", recent: "1")
        // 5h: limit 100 − ceil(30 × 300 / 3600 = 2.5) = 97, 17 points at 30%/h
        // is 34 minutes; 7d: limit 99, 2 points at 1%/h is two hours.
        let soonest = PaceRules.goExpiry([weekly, fiveHour], cap: .safe, horizon: 0)
        #expect(soonest?.label == "5h")
        #expect(soonest.map { abs($0.seconds - 2_040) < 0.01 } == true, "\(String(describing: soonest))")
        // A window that resets before it fills does not end the verdict.
        let resetsFirst = Self.window("5h", identity: "five_hour", percent: 80, resets: "600", recent: "30")
        #expect(PaceRules.goExpiry([resetsFirst, weekly], cap: .safe, horizon: 0)?.label == "7d")
        // Nor does one already due, or one not climbing.
        let due = Self.window("5h", identity: "five_hour", percent: 96, resets: "0", recent: "30")
        let falling = Self.window("5h", identity: "five_hour", percent: 50, recent: "-4")
        #expect(PaceRules.goExpiry([due, falling], cap: .safe, horizon: 0) == nil)
        // A cap and a margin move the limit it is reached at.
        #expect(PaceRules.goExpiry([fiveHour], cap: .value("85"), horizon: 0).map { abs($0.seconds - 600) < 0.01 } == true)
        #expect(PaceRules.goExpiry([fiveHour], cap: .safe, margin: 2, horizon: 0).map { abs($0.seconds - 1_800) < 0.01 } == true)
    }

    @Test func goLifeIsBetweenAMinuteAndTheShelfLife() {
        func expiry(_ s: Double) -> PaceRules.Expiry { .init(seconds: s, label: "5h", why: "limit", limit: 95, burn: 45) }
        #expect(PaceRules.goLife(nil, maxAge: 900) == 900)
        #expect(PaceRules.goLife(expiry(560), maxAge: 900) == 560)
        #expect(PaceRules.goLife(expiry(5_000), maxAge: 900) == 900)
        #expect(PaceRules.goLife(expiry(8), maxAge: 900) == 60)
        #expect(PaceRules.goLife(expiry(8), maxAge: 30) == 30)
    }

    @Test func utcClockIsTheTimeOfDayInUTC() {
        #expect(PaceFormat.utcClock(Date(timeIntervalSince1970: 1_800_000_000)) == "08:00Z")
        #expect(PaceFormat.utcClock(Date(timeIntervalSince1970: 1_800_000_000 + 14 * 3_600 + 41 * 60 + 59)) == "22:41Z")
        #expect(PaceFormat.utcClock(Date(timeIntervalSince1970: -60)) == "23:59Z")
    }

    // MARK: - A switch resumes only onto a login with room (#313)

    /// The login switched to: 5h at `ratio`, resetting in 15 minutes.
    private static func switched(to ratio: String, recent: String? = "0", resets: String = "900") -> String {
        var text = """
        pacer_rate_limit_used_ratio{account="org-home",window="five_hour"} \(ratio)
        pacer_rate_limit_reset_seconds{account="org-home",window="five_hour"} \(resets)
        pacer_rate_limit_sample_age_seconds{account="org-home",window="five_hour"} 0
        pacer_rate_limit_used_ratio{account="org-home",window="seven_day"} 0.40
        pacer_rate_limit_reset_seconds{account="org-home",window="seven_day"} 300000
        pacer_account_info{account="org-home",name="h",active="true"} 1
        """
        if let recent {
            text += "\npacer_rate_limit_recent_burn_percent_per_hour{account=\"org-home\",window=\"five_hour\"} \(recent)"
        }
        return text
    }

    /// The issue's second case: every waiting session resumed onto a login
    /// at 97%, under its 99% limit, and filled it in four minutes.
    @Test func aSwitchOntoANearlyFullLoginDoesNotResume() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        var polls = 0
        let result = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            polls = n
            if n == 1 { try? box.setMetrics(Self.switched(to: "0.97")) }
            // That login's 5h window resets.
            if n == 3 { try? box.setMetrics(Self.switched(to: "0.04", resets: "18000")) }
        })
        #expect(result.status == 0, "\(result.out)")
        #expect(polls == 3, "it resumed onto 97%:\n\(result.out)")
        #expect(result.out.contains("account switched (org-work → org-home), but 5h at 97% on org-home is 2 points below its 99% limit, short of the 5 a resume needs — holding for more room or its reset in ~15m"),
                "\(result.out)")
        #expect(result.out.components(separatedBy: "account switched").count == 2, "said once:\n\(result.out)")
        #expect(!result.out.contains("would pass the limit now"), "\(result.out)")
        #expect(result.out.contains("pace: reset — the 5h window rolled over"), "\(result.out)")
    }

    @Test func aSwitchHoldIsWhatStatusReads() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        var read = ""
        _ = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            if n == 1 { try? box.setMetrics(Self.switched(to: "0.97")) }
            if n == 2 { read = runPace(box, ["status", "--no-refresh"]).out }
            if n == 3 { try? box.setMetrics(Self.switched(to: "0.04", resets: "18000")) }
        })
        #expect(read.hasPrefix("paused: waiting for room: 5h at 97% on org-home is 2 points below its 99% limit"), "\(read)")
    }

    @Test func aSwitchOntoALoginWithRoomResumes() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        var polls = 0
        let result = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            polls = n
            if n == 1 { try? box.setMetrics(Self.switched(to: "0.60")) }
        })
        #expect(result.status == 0)
        #expect(polls == 1, "\(result.out)")
        #expect(result.out.contains("account switched (org-work → org-home) — headroom on the new login (5h 60%, 7d 40%). Resume."),
                "\(result.out)")
    }

    @Test func theRoomAResumeNeedsIsTwentyMinutesOfBurn() throws {
        // 85% against 96% (45%/h, read just now): 11 points, where 20
        // minutes at 45%/h is 15.
        let busy = Self.switched(to: "0.85", recent: "45")
        let box = try PaceSandbox(metrics: Self.burning())
        var polls = 0
        let held = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            polls = n
            if n == 1 { try? box.setMetrics(busy) }
            if n == 3 { try? box.setMetrics(Self.switched(to: "0.04", resets: "18000")) }
        })
        #expect(polls == 3, "\(held.out)")
        #expect(held.out.contains("5h at 85% on org-home is 11 points below its 96% limit, short of the 15 a resume needs (20m at 45%/h)"),
                "\(held.out)")
        // A fixed headroom is what it says.
        try box.setMetrics(Self.burning())
        let fixed = runPace(box, ["wait", "--interval", "5", "--resume-headroom", "10"], onSleep: { n in
            if n == 1 { try? box.setMetrics(busy) }
        })
        #expect(fixed.status == 0)
        #expect(fixed.out.contains("headroom on the new login"), "\(fixed.out)")
    }

    @Test func withoutABurnOnTheNewLoginTheOldLoginsRateDecides() throws {
        // 88% against 98%: 10 points. org-work was burning 36%/h: 12 needed.
        let quiet = Self.switched(to: "0.88", recent: nil)
        let box = try PaceSandbox(metrics: Self.burning())
        var polls = 0
        let held = runPace(box, ["wait", "--interval", "5"], onSleep: { n in
            polls = n
            if n == 1 { try? box.setMetrics(quiet) }
            if n == 3 { try? box.setMetrics(Self.switched(to: "0.04", resets: "18000")) }
        })
        #expect(polls == 3, "\(held.out)")
        #expect(held.out.contains("5h at 88% on org-home is 10 points below its 98% limit, short of the 12 a resume needs (20m at the old login's 36%/h)"),
                "\(held.out)")
        try box.setMetrics(Self.burning())
        let env = runPace(box, ["wait", "--interval", "5"], extra: ["PACE_RESUME_HEADROOM": "5"], onSleep: { n in
            if n == 1 { try? box.setMetrics(quiet) }
        })
        #expect(env.status == 0)
        #expect(env.out.contains("headroom on the new login"), "\(env.out)")
    }

    @Test func noResumeHeadroomResumesOnAnyRoomAsBefore() throws {
        let box = try PaceSandbox(metrics: Self.burning())
        let result = runPace(box, ["wait", "--interval", "5", "--resume-headroom", "0"], onSleep: { n in
            if n == 1 { try? box.setMetrics(Self.switched(to: "0.97")) }
        })
        #expect(result.status == 0)
        #expect(result.out.contains("headroom on the new login"), "\(result.out)")
    }

    @Test func aResumeHeadroomMustBeWholePointsOrAuto() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        for bad in ["-1", "lots", "2.5"] {
            let result = runPace(box, ["wait", "--resume-headroom", bad])
            #expect(result.status == 1, "\(bad): \(result.out)")
            #expect(result.out.contains("--resume-headroom takes a whole number"), "\(result.out)")
        }
        let env = runPace(box, ["wait"], extra: ["PACE_RESUME_HEADROOM": "x"])
        #expect(env.status == 1)
        #expect(env.out.contains("PACE_RESUME_HEADROOM"))
    }

    @Test func resumeHeadroomRule() {
        let row = Self.window("5h", identity: "five_hour", percent: 90, recent: "45")
        #expect(PaceRules.resumeHeadroom(row, fixed: nil, fallbackBurn: nil) == (15, 45))
        #expect(PaceRules.resumeHeadroom(row, fixed: 3, fallbackBurn: nil) == (3, nil))
        let slow = Self.window("5h", identity: "five_hour", percent: 90, recent: "6")
        #expect(PaceRules.resumeHeadroom(slow, fixed: nil, fallbackBurn: 60) == (5, nil), "its own rate, though slow")
        let unknown = Self.window("5h", identity: "five_hour", percent: 90)
        #expect(PaceRules.resumeHeadroom(unknown, fixed: nil, fallbackBurn: 60) == (20, 60))
        #expect(PaceRules.resumeHeadroom(unknown, fixed: nil, fallbackBurn: nil) == (5, nil))
    }

    // MARK: - pacer feedback (#268)

    private func inbox(_ box: PaceSandbox) -> [[String: Any]] {
        let url = box.dir.appendingPathComponent(".claude/pace/feedback.jsonl")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    @Test func feedbackSavesOneLineLocallyAndSendsNothing() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85"])
        let log = PaceRequestLog()
        let text = #"ran `pacer gate --cap 85`, got "PAUSE — Fable" & expected GO; 50% + more"#
        let result = runPace(box, ["feedback", text], extra: ["CLAUDE_CODE_SESSION_ID": "abc-123"],
                             onGet: log.record)
        #expect(result.status == 0, "\(result.out)")
        #expect(log.all.isEmpty, "feedback must not touch the network: \(log.all)")
        #expect(result.out.contains("feedback saved to \(box.dir.path)/.claude/pace/feedback.jsonl"))
        #expect(result.out.contains("nothing was sent anywhere"))
        let lines = inbox(box)
        #expect(lines.count == 1)
        let entry = try #require(lines.first)
        #expect(entry["text"] as? String == text)
        #expect(entry["sessionId"] as? String == "abc-123")
        #expect((entry["ts"] as? String)?.hasSuffix("Z") == true)
        #expect(entry["version"] is String)
        #expect(entry["cwd"] is String)
        let verdict = try #require(entry["lastVerdict"] as? [String: Any])
        #expect(verdict["status"] as? String == "paused")
        #expect(verdict["tripWindow"] as? String == "Fable")
    }

    @Test func feedbackOffersAPrefilledIssueThatCarriesNothingPrivate() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        _ = runPace(box, ["gate", "--cap", "85"])
        let result = runPace(box, ["feedback", "wait", "said", "reset", "at", "97%", "&", "#1"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123"])
        let line = try #require(result.out.split(separator: "\n").first { $0.hasPrefix("https://") })
        #expect(line.hasPrefix(Pace.issuesURL + "?title="))
        let items = try #require(URLComponents(string: String(line))?.queryItems)
        let title = try #require(items.first { $0.name == "title" }?.value)
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(items.count == 2, "a & or # in the text must not split the query")
        #expect(title == "pacer feedback: wait said reset at 97% & #1")
        #expect(body.hasPrefix("wait said reset at 97% & #1\n"))
        #expect(body.contains("Last verdict: paused — Fable at 95% >= cap 85%"), "\(body)")
        #expect(body.contains("cap 85, margin 0"), "\(body)")
        #expect(!body.contains("abc-123"), "no session id in a public issue")
        #expect(!body.contains(box.dir.path), "no paths in a public issue")
        #expect(!body.contains(FileManager.default.currentDirectoryPath))
    }

    @Test func feedbackAppendsAndReadsThisSessionsVerdict() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let session = ["CLAUDE_CODE_SESSION_ID": "0f3c9a12-aaaa"]
        _ = runPace(box, ["gate", "--cap", "85", "--window", "5h"], unsetState: true, extra: session)
        #expect(runPace(box, ["feedback", "first"], unsetState: true, extra: session).status == 0)
        #expect(runPace(box, ["feedback", "second"], unsetState: true).status == 0)
        let lines = inbox(box)
        #expect(lines.map { $0["text"] as? String } == ["first", "second"])
        #expect((lines[0]["lastVerdict"] as? [String: Any])?["status"] as? String == "go")
        #expect((lines[0]["stateFile"] as? String)?.hasSuffix("state-session-0f3c9a12.json") == true)
        #expect(lines[1]["lastVerdict"] == nil, "no session, no state.json: no verdict")
        #expect(lines[1]["sessionId"] == nil)
    }

    @Test func feedbackNeedsText() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["feedback", "  "])
        #expect(result.status == 1)
        #expect(result.out.contains("feedback needs the text"))
        #expect(inbox(box).isEmpty)
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

    // MARK: - --margin and safecap (#263)

    /// 5h at 95%, burning 36%/h on a fresh reading: safe limit 97. 7d at 50%,
    /// no burn measured: 98.
    private static let margined = """
    pacer_rate_limit_used_ratio{account="org",window="five_hour"} 0.95
    pacer_rate_limit_reset_seconds{account="org",window="five_hour"} 3600
    pacer_rate_limit_recent_burn_percent_per_hour{account="org",window="five_hour"} 36
    pacer_rate_limit_sample_age_seconds{account="org",window="five_hour"} 0
    pacer_rate_limit_used_ratio{account="org",window="seven_day"} 0.50
    pacer_rate_limit_reset_seconds{account="org",window="seven_day"} 300000
    pacer_account_info{account="org",name="o",active="true"} 1
    """

    @Test func aMarginStopsThatManyPointsShortOfEachSafeLimit() throws {
        let box = try PaceSandbox(metrics: Self.margined)
        let plain = runPace(box, ["gate"])
        #expect(plain.status == 0)
        #expect(plain.out.contains("(safe limit 5h 97%, 7d 98%)"), "\(plain.out)")
        let one = runPace(box, ["gate", "--margin", "1"])
        #expect(one.status == 0)
        #expect(one.out.contains("(safe limit 5h 97% − 1, 7d 98% − 1)"), "\(one.out)")
        let three = runPace(box, ["gate", "--margin", "3"])
        #expect(three.status == 10)
        #expect(three.out.contains("5h at 95% >= safe limit 97% − 3"), "\(three.out)")
        #expect(box.stateText.contains("\"margin\": 3"))
        #expect(box.stateText.contains("safe limit 97% − 3"))
    }

    @Test func aMarginWithACapTakesTheLowerOfTheTwo() throws {
        let box = try PaceSandbox(metrics: Self.margined)
        // A cap alone replaces the safe limit, as it always did.
        #expect(runPace(box, ["gate", "--cap", "96"]).status == 0)
        // min(99, 97 − 3) = 94: the margined safe limit trips.
        let safer = runPace(box, ["gate", "--cap", "99", "--margin", "3"])
        #expect(safer.status == 10)
        #expect(safer.out.contains("safe limit 97% − 3"), "\(safer.out)")
        // min(90, 97 − 1) = 90: the cap trips, and says so.
        let capped = runPace(box, ["gate", "--cap", "90", "--margin", "1"])
        #expect(capped.status == 10)
        #expect(capped.out.contains("5h at 95% >= cap 90%"), "\(capped.out)")
        let go = runPace(box, ["gate", "--cap", "99", "--margin", "1", "--window", "7d"])
        #expect(go.status == 0)
        #expect(go.out.contains("(cap 99%, safe limit 7d 98% − 1)"), "\(go.out)")
    }

    /// #263's case: under a burst the safe limit falls below a fixed cap, and
    /// only the margin keeps tracking it.
    @Test func underABurstAMarginStillStopsWhereAFixedCapWouldNot() throws {
        let box = try PaceSandbox(metrics: """
        pacer_rate_limit_used_ratio{account="org",window="five_hour"} 0.92
        pacer_rate_limit_reset_seconds{account="org",window="five_hour"} 3600
        pacer_rate_limit_recent_burn_percent_per_hour{account="org",window="five_hour"} 120
        pacer_rate_limit_sample_age_seconds{account="org",window="five_hour"} 0
        pacer_account_info{account="org",name="o",active="true"} 1
        """)
        #expect(runPace(box, ["gate", "--cap", "94"]).status == 0)
        #expect(runPace(box, ["gate", "--margin", "3"]).status == 10)
    }

    @Test func paceMarginSetsTheMarginOnce() throws {
        let box = try PaceSandbox(metrics: Self.margined)
        let result = runPace(box, ["gate"], extra: ["PACE_MARGIN": "3"])
        #expect(result.status == 10)
        #expect(result.out.contains("− 3"))
        #expect(runPace(box, ["gate", "--margin", "0"], extra: ["PACE_MARGIN": "3"]).status == 0,
                "the flag beats the environment")
    }

    @Test func aMarginMustBeWholePointsAndNotNegative() throws {
        let box = try PaceSandbox(metrics: Self.margined)
        for bad in ["-1", "two", "1.5"] {
            let result = runPace(box, ["gate", "--margin", bad])
            #expect(result.status == 1, "\(bad)")
            #expect(result.out.contains("whole number of points"))
        }
        #expect(runPace(box, ["gate"], extra: ["PACE_MARGIN": "x"]).status == 1)
    }

    @Test func statusRefusesAVerdictGatedWithAnotherMargin() throws {
        let box = try PaceSandbox(metrics: Self.margined)
        #expect(runPace(box, ["gate", "--margin", "3"]).status == 10)
        #expect(runPace(box, ["status"]).status == 10)
        #expect(runPace(box, ["status", "--margin", "3"]).status == 10)
        let other = runPace(box, ["status", "--margin", "0"])
        #expect(other.status == 3)
        #expect(other.out.contains("margin 3, not 0"), "\(other.out)")
        #expect(runPace(box, ["status"], extra: ["PACE_MARGIN": "1"]).status == 3)
    }

    @Test func aBareWaitKeepsTheGatesMargin() throws {
        let box = try PaceSandbox(metrics: Self.margined)
        #expect(runPace(box, ["gate", "--margin", "3"]).status == 10)
        let wait = runPace(box, ["wait", "--max-wait", "60"])
        #expect(wait.out.contains("--margin 3"), "\(wait.out)")
        #expect(wait.status == 20)
    }

    @Test func safecapPrintsTheLimitTheGateWouldApply() throws {
        let box = try PaceSandbox(metrics: Self.margined)
        let plain = runPace(box, ["safecap"])
        #expect(plain.status == 0)
        #expect(plain.out == "5h         97\n7d         98\n", "\(plain.out)")
        #expect(runPace(box, ["safecap", "--margin", "3"]).out == "5h         94\n7d         95\n")
        #expect(runPace(box, ["safecap", "--cap", "90", "--margin", "1"]).out == "5h         90\n7d         90\n")
        #expect(runPace(box, ["safecap", "--window", "7d"]).out == "7d         98\n")
        #expect(runPace(box, ["safecap", "--window", "1h"]).status == 1, "a selector matching nothing is an error")
    }

    @Test func safecapListsOnlyTheWindowsThatBindTheModel() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        #expect(runPace(box, ["safecap"]).out.contains("Fable"))
        let opus = runPace(box, ["safecap", "--model", "opus"])
        #expect(opus.status == 0)
        #expect(!opus.out.contains("Fable"))
        #expect(opus.out.contains("5h"))
    }

    // MARK: - No --model in a known session is --model auto (#264)

    @Test func noModelInAKnownSessionGatesAsAuto() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try sessionStub(["claude-opus-5"])
        defer { server.stop() }
        let result = runPace(box, ["gate", "--cap", "85"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base])
        // The Fable cap at 95% does not bind Opus work.
        #expect(result.status == 0, "\(result.out)")
        #expect(result.out.contains("(model auto: detected claude-opus-5)"), "\(result.out)")
        #expect(box.stateText.contains("\"autoModel\": true"))
        #expect(box.stateText.contains("model auto: detected claude-opus-5"))
    }

    @Test func noModelWithoutASessionStillBindsEveryWindow() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let result = runPace(box, ["gate", "--cap", "85"], extra: ["CLAUDE_CODE_SESSION_ID": ""])
        #expect(result.status == 10)
        #expect(result.out.contains("Fable"))
        #expect(!result.out.contains("model auto"))
        #expect(box.stateText.contains("\"autoModel\": false"))
    }

    @Test func noModelInASessionPacerHasNotSeenBindsEveryWindowAndSaysSo() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try PaceStubServer(status: 404, body: "No turns recorded\n")
        defer { server.stop() }
        let result = runPace(box, ["gate", "--cap", "85"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "unknown", "PACE_SESSION_API": server.base])
        #expect(result.status == 10)
        #expect(result.out.contains("Fable"))
        #expect(result.out.contains("(model auto: unknown — every window binds)"), "\(result.out)")
    }

    @Test func modelAllStillBindsEveryWindowInAKnownSession() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try sessionStub(["claude-opus-5"])
        defer { server.stop() }
        let result = runPace(box, ["gate", "--cap", "85", "--model", "all"],
                             extra: ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base])
        #expect(result.status == 10)
        #expect(result.out.contains("Fable"))
        #expect(!result.out.contains("model auto"))
    }

    @Test func aBareWaitAsksAgainWhenTheGateWasAuto() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try sessionStub(["claude-fable-5-1"])
        defer { server.stop() }
        let env = ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base]
        #expect(runPace(box, ["gate", "--cap", "85"], extra: env).status == 10)
        let wait = runPace(box, ["wait", "--interval", "5", "--max-wait", "60"], extra: env)
        #expect(wait.out.contains("--model auto"), "\(wait.out)")
        #expect(wait.status == 20)
    }

    @Test func statusModelAutoTakesAnAutoVerdictWithoutAskingPacer() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        let server = try sessionStub(["claude-opus-5"])
        defer { server.stop() }
        let env = ["CLAUDE_CODE_SESSION_ID": "abc-123", "PACE_SESSION_API": server.base]
        #expect(runPace(box, ["gate", "--cap", "85", "--margin", "2"], extra: env).status == 0)
        let log = PaceRequestLog()
        #expect(runPace(box, ["status", "--model", "auto"], extra: env, onGet: log.record).status == 0)
        #expect(log.all.isEmpty, "\(log.all)")
        // ...but still by its margin.
        #expect(runPace(box, ["status", "--model", "auto", "--margin", "0"], extra: env).status == 3)
    }

    @Test func aBareStatusInAKnownSessionJudgesTheVerdictItFinds() throws {
        let box = try PaceSandbox(metrics: Self.metrics)
        #expect(runPace(box, ["gate", "--cap", "85", "--model", "opus"]).status == 0)
        let status = runPace(box, ["status"], extra: ["CLAUDE_CODE_SESSION_ID": "abc-123",
                                                      "PACE_SESSION_API": "http://127.0.0.1:9"])
        #expect(status.status == 0, "\(status.out)")
        #expect(status.out.hasPrefix("go (until "), "\(status.out)")
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
