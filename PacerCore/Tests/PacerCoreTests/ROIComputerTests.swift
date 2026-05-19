import Foundation
import Testing
@testable import PacerCore

@Suite("ROIComputer")
struct ROIComputerTests {

    private func commit(at: Date, hash: String = "abc", add: Int = 5, rem: Int = 2) -> GitLogReader.Commit {
        GitLogReader.Commit(hash: hash, date: at, linesAdded: add, linesRemoved: rem)
    }

    private func session(
        _ id: String,
        from: Date,
        to: Date,
        cost: Double,
        project: String = "/repo"
    ) -> ROIComputer.SessionWindow {
        ROIComputer.SessionWindow(
            sessionId: id,
            projectPath: project,
            firstSeenAt: from,
            lastSeenAt: to,
            costUSD: cost
        )
    }

    @Test func attributesCommitToEnclosingSession() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let s = session("s1", from: start, to: start.addingTimeInterval(600), cost: 4)
        let c1 = commit(at: start.addingTimeInterval(120), hash: "a")
        let c2 = commit(at: start.addingTimeInterval(450), hash: "b")
        let roi = ROIComputer.computeProject(
            projectPath: "/repo",
            commits: [c1, c2],
            sessions: [s]
        )
        #expect(roi.commitCount == 2)
        #expect(roi.attributedCostUSD == 4)
        #expect(roi.unattributedCommits == 0)
        #expect(roi.attributedSessions == 1)
    }

    @Test func unattributedCommitWhenNoSessionCovers() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let s = session("s1", from: start, to: start.addingTimeInterval(60), cost: 4)
        let c1 = commit(at: start.addingTimeInterval(3600), hash: "a") // far outside
        let roi = ROIComputer.computeProject(
            projectPath: "/repo",
            commits: [c1],
            sessions: [s]
        )
        #expect(roi.commitCount == 1)
        #expect(roi.attributedCostUSD == 0)
        #expect(roi.unattributedCommits == 1)
        #expect(roi.attributedSessions == 0)
    }

    @Test func slackAllowsCommitsSlightlyAfterSession() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(600)
        let s = session("s1", from: start, to: end, cost: 4)
        // 30 seconds after the session ended — within attributionSlack.
        let c = commit(at: end.addingTimeInterval(30), hash: "a")
        let roi = ROIComputer.computeProject(
            projectPath: "/repo",
            commits: [c],
            sessions: [s]
        )
        #expect(roi.attributedCostUSD == 4)
        #expect(roi.unattributedCommits == 0)
    }

    @Test func sessionCostDoesNotDoubleCountAcrossCommits() {
        // Session with $4 cost and TWO commits in its window. The
        // attributed cost is the session's $4 — not 4 + 4. The fact
        // that we have multiple commits in the window means $/commit
        // = $2, which is the meaningful per-commit cost.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let s = session("s1", from: start, to: start.addingTimeInterval(600), cost: 4)
        let c1 = commit(at: start.addingTimeInterval(120), hash: "a")
        let c2 = commit(at: start.addingTimeInterval(450), hash: "b")
        let roi = ROIComputer.computeProject(
            projectPath: "/repo",
            commits: [c1, c2],
            sessions: [s]
        )
        #expect(roi.attributedCostUSD == 4)
        if let cpc = roi.costPerCommit {
            #expect(abs(cpc - 2.0) < 1e-9)
        } else {
            Issue.record("expected costPerCommit, got nil")
        }
    }

    @Test func sessionWithNoCommitsContributesNothing() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Two sessions; only one has a commit.
        let s1 = session("s1", from: start, to: start.addingTimeInterval(60), cost: 5)
        let s2 = session("s2", from: start.addingTimeInterval(3600), to: start.addingTimeInterval(3660), cost: 3)
        let c = commit(at: start.addingTimeInterval(30), hash: "a")
        let roi = ROIComputer.computeProject(
            projectPath: "/repo",
            commits: [c],
            sessions: [s1, s2]
        )
        // Only s1's $5 is attributed; s2's $3 is invisible (no commit
        // landed inside it). Total $8 was spent on Claude that the
        // user paid for, but only $5 produced visible commit-level
        // output.
        #expect(roi.attributedCostUSD == 5)
        #expect(roi.attributedSessions == 1)
    }

    @Test func linesAddedAndRemovedSumAcrossAllCommits() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let s = session("s1", from: start, to: start.addingTimeInterval(600), cost: 4)
        let c1 = commit(at: start.addingTimeInterval(60), add: 10, rem: 3)
        let c2 = commit(at: start.addingTimeInterval(120), add: 4, rem: 1)
        let roi = ROIComputer.computeProject(
            projectPath: "/repo",
            commits: [c1, c2],
            sessions: [s]
        )
        #expect(roi.linesAdded == 14)
        #expect(roi.linesRemoved == 4)
    }

    @Test func costPerLineIsNilWhenNoLOC() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let s = session("s1", from: start, to: start.addingTimeInterval(60), cost: 4)
        let c = commit(at: start.addingTimeInterval(30), add: 0, rem: 0)
        let roi = ROIComputer.computeProject(
            projectPath: "/repo",
            commits: [c],
            sessions: [s]
        )
        #expect(roi.costPerLine == nil)
    }
}

@Suite("GitLogReader.parse")
struct GitLogReaderParseTests {

    @Test func parsesEmptyOutput() {
        let commits = GitLogReader.parse(output: "")
        #expect(commits.isEmpty)
    }

    @Test func parsesSingleCommit() throws {
        let output = """
        COMMIT abc123 2026-05-19T10:30:00-07:00
        5\t2\tfile1.swift
        3\t0\tfile2.swift
        """
        let commits = GitLogReader.parse(output: output)
        #expect(commits.count == 1)
        let c = commits[0]
        #expect(c.hash == "abc123")
        #expect(c.linesAdded == 8)
        #expect(c.linesRemoved == 2)
    }

    @Test func parsesMultipleCommitsSeparatedByBlankLines() {
        let output = """
        COMMIT abc 2026-05-19T10:30:00-07:00
        5\t2\tfile1.swift

        COMMIT def 2026-05-18T11:00:00-07:00
        10\t5\tfile2.swift
        """
        let commits = GitLogReader.parse(output: output)
        #expect(commits.count == 2)
        #expect(commits[0].hash == "abc")
        #expect(commits[0].linesAdded == 5)
        #expect(commits[1].hash == "def")
        #expect(commits[1].linesAdded == 10)
    }

    @Test func binaryFileColumnsTreatedAsZero() {
        // Git emits "-\t-\tfile" for binary files.
        let output = """
        COMMIT abc 2026-05-19T10:30:00-07:00
        5\t2\tfile1.swift
        -\t-\timage.png
        """
        let commits = GitLogReader.parse(output: output)
        #expect(commits.count == 1)
        #expect(commits[0].linesAdded == 5)
        #expect(commits[0].linesRemoved == 2)
    }

    @Test func skipsCommitsWithUnparseableTimestamp() {
        // A garbled timestamp drops the commit; we don't synthesize a
        // fake date because that would corrupt downstream window math.
        let output = """
        COMMIT abc not-a-date
        5\t2\tfile.swift
        """
        let commits = GitLogReader.parse(output: output)
        #expect(commits.isEmpty)
    }
}
