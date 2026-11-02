import Foundation
import Testing
@testable import PacerCore

// Everything that leaves the Mac goes through the scrubber, so these tests are
// the privacy promise: each one is a real shape of string that has, or could
// have, ended up in an error message, a crash reason or a problem report.

@Suite("Telemetry scrubber")
struct TelemetryScrubberTests {

    private func scrub(_ s: String) -> String { TelemetryScrubber.scrub(s, home: "/Users/alice") }

    @Test("the home directory becomes ~")
    func home() {
        #expect(scrub("couldn't open /Users/alice/.claude/projects/x.jsonl")
                == "couldn't open ~/.claude/projects/x.jsonl")
    }

    @Test("another user's path loses the user name too")
    func otherUser() {
        #expect(scrub("at /Users/bob/Library/Logs") == "at ~/Library/Logs")
    }

    @Test("Claude Code's dashed project folder name is hidden, the path shape kept")
    func dashedProject() {
        #expect(scrub("/Users/alice/.claude/projects/-Users-alice-Code-acme-api/abc.jsonl")
                == "~/.claude/projects/<project>/abc.jsonl")
    }

    @Test("emails are removed")
    func email() {
        #expect(scrub("account somebody.name+tag@example.co.uk failed") == "account <email> failed")
    }

    @Test("bearer tokens and API keys are removed")
    func tokens() {
        #expect(scrub("Authorization: Bearer abc.def-ghi_123") == "Authorization: <redacted>")
        #expect(scrub("key sk-ant-oat01-AbCdEf123456 used") == "key <redacted> used")
        #expect(scrub("ghp_0123456789abcdefABCDEF") == "<redacted>")
        #expect(scrub("github_pat_11ABCDEFG0123456789") == "<redacted>")
    }

    @Test("long hex and base64 runs are removed, UUIDs kept")
    func longRuns() {
        #expect(scrub("hash 0123456789abcdef0123456789abcdef01") == "hash <redacted>")
        #expect(scrub("tok QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaA==") == "tok <redacted>")
        let uuid = "33434d12-5757-3524-84da-a4caf748dab7"
        #expect(scrub("image \(uuid)") == "image \(uuid)")
    }

    @Test("ordinary text is untouched")
    func ordinary() {
        let s = "scan cycle took 1203 ms (phase: dailyRecompute) on macOS 15.4"
        #expect(scrub(s) == s)
    }

    @Test("dictionaries are scrubbed recursively, keys kept")
    func dictionary() {
        let out = TelemetryScrubber.scrub(
            ["path": "/Users/alice/x", "nested": ["email": "a@b.com"], "list": ["/Users/alice/y"], "n": 3],
            home: "/Users/alice")
        #expect(out["path"] as? String == "~/x")
        #expect((out["nested"] as? [String: Any])?["email"] as? String == "<email>")
        #expect((out["list"] as? [Any])?.first as? String == "~/y")
        #expect(out["n"] as? Int == 3)
    }
}
