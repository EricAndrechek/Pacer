import Foundation
import Testing
@testable import PacerCore

@Suite("CLI run log")
struct CLIRunLogTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cli-runs-\(UUID().uuidString).log")
    }

    @Test("start and end lines round-trip through the file")
    func roundTrip() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        CLIRunLog.recordStart(runId: "abc12345", subcommand: "gate", at: t, to: url)
        CLIRunLog.recordEnd(runId: "abc12345", subcommand: "gate", exitCode: 0, milliseconds: 56,
                            source: .api, at: t.addingTimeInterval(0.056), to: url)
        let lines = CLIRunLog.lines(at: url)
        #expect(lines.count == 2)
        #expect(lines[1].exitCode == 0 && lines[1].milliseconds == 56 && lines[1].source == "api")
    }

    @Test("only known subcommand names are logged")
    func safeName() {
        let known: Set<String> = ["gate", "status"]
        #expect(CLIRunLog.safeName("gate", known: known) == "gate")
        #expect(CLIRunLog.safeName("/Users/alice/secret", known: known) == "other")
    }

    @Test("the summary counts runs, failures, durations and hung runs; wait is never hung")
    func summary() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }
        let lines: [CLIRunLog.Line] = [
            .init(at: at(0), kind: .start, runId: "a", subcommand: "gate", exitCode: nil, milliseconds: nil, source: nil),
            .init(at: at(1), kind: .end, runId: "a", subcommand: "gate", exitCode: 0, milliseconds: 40, source: "api"),
            .init(at: at(2), kind: .start, runId: "b", subcommand: "gate", exitCode: nil, milliseconds: nil, source: nil),
            .init(at: at(3), kind: .end, runId: "b", subcommand: "gate", exitCode: 1, milliseconds: 900, source: "offline"),
            .init(at: at(4), kind: .start, runId: "c", subcommand: "status", exitCode: nil, milliseconds: nil, source: nil),
            .init(at: at(5), kind: .start, runId: "d", subcommand: "wait", exitCode: nil, milliseconds: nil, source: nil),
            // Started 1 minute before `until`: still running, not counted.
            .init(at: at(3540), kind: .start, runId: "e", subcommand: "status", exitCode: nil, milliseconds: nil, source: nil),
        ]
        let s = CLIRunLog.summary(lines, since: base, until: at(3600))
        #expect(s["gate"]?.runs == 2)
        #expect(s["gate"]?.failures == 1)
        #expect(s["gate"]?.durationsMs == [40, 900])
        #expect(s["gate"]?.bySource == ["api": 1, "offline": 1])
        #expect(s["status"]?.hung == 1 && s["status"]?.runs == 1)
        #expect(s["wait"] == nil)
    }

    @Test("malformed and truncated lines are skipped")
    func malformed() {
        #expect(CLIRunLog.parse("garbage") == nil)
        #expect(CLIRunLog.parse("2026-11-02T16:03:12.345Z end abc gate exit=0") == nil)
    }
}
