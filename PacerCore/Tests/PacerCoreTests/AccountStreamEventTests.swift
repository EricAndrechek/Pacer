import Foundation
import Testing
@testable import PacerCore

// #192: `/v1/stream` pushes an `account` event the moment the active login
// changes. The server is in the app target and has no test seam of its own;
// what a client relies on — the payload, its framing, and when it fires — is
// here. Fictional ids throughout.

@Suite("The /v1/stream account event")
struct AccountStreamEventTests {

    @Test("encodes as {activeAccountId, since}, ISO-8601, keys sorted")
    func encoding() throws {
        let change = PacerAccountChange(
            activeAccountId: "org-new", since: Date(timeIntervalSince1970: 1_791_547_200))
        let json = try change.encodedJSON()
        #expect(json == """
        {
          "activeAccountId" : "org-new",
          "since" : "2026-10-09T12:00:00Z"
        }
        """)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(PacerAccountChange.self, from: Data(json.utf8)) == change)
        #expect(PacerAccountChange.eventName == "account")
    }

    @Test("framed as one SSE event, one data line per payload line")
    func framing() throws {
        let json = try PacerAccountChange(
            activeAccountId: "org-new", since: Date(timeIntervalSince1970: 1_791_547_200)).encodedJSON()
        let frame = PacerSSE.frame(event: PacerAccountChange.eventName, data: json)
        #expect(frame == """
        event: account
        data: {
        data:   "activeAccountId" : "org-new",
        data:   "since" : "2026-10-09T12:00:00Z"
        data: }


        """)
        // What a client does with it: join the data lines back.
        let rejoined = frame.split(separator: "\n")
            .filter { $0.hasPrefix("data: ") }
            .map { $0.dropFirst("data: ".count) }
            .joined(separator: "\n")
        #expect(rejoined == json)
    }

    @Test("fires on a change only — not on the same login re-asserted, not on unknown")
    func detector() {
        var detector = PacerAccountChange.Detector(last: "org-a")
        let at = Date(timeIntervalSince1970: 1_791_547_200)
        #expect(detector.observe("org-a", since: at) == nil)      // republished at launch
        #expect(detector.observe(nil, since: at) == nil)          // not known yet
        #expect(detector.observe("org-b", since: at)
                == PacerAccountChange(activeAccountId: "org-b", since: at))
        #expect(detector.observe("org-b", since: at) == nil)
        #expect(detector.observe("org-a", since: at)?.activeAccountId == "org-a")

        var fresh = PacerAccountChange.Detector(last: nil)
        #expect(fresh.observe("org-a", since: at)?.activeAccountId == "org-a")
    }
}

