import Testing
@testable import PacerCore

// #239: the pace chart re-read every account's series on any account's write.
// The ledger is what lets it fetch only the account that moved.
@Suite("Rate-limit writes, per account")
struct RateLimitWriteLedgerTests {

    @Test("a write moves only its own account's generation")
    func perAccount() {
        var ledger = RateLimitWriteLedger()
        #expect(ledger.generation(of: "org-a") == 0)
        ledger.record(1, account: "org-a")
        ledger.record(2, account: "org-b")
        ledger.record(3, account: "org-b")
        #expect(ledger.generation(of: "org-a") == 1)   // B's writes leave A's series current
        #expect(ledger.generation(of: "org-b") == 3)
        #expect(ledger.generation(of: "org-c") == 0)
    }

    @Test("a write naming no account counts for every account")
    func unattributed() {
        var ledger = RateLimitWriteLedger()
        ledger.record(1, account: "org-a")
        ledger.record(2, account: nil)
        #expect(ledger.generation(of: "org-a") == 2)
        #expect(ledger.generation(of: "org-c") == 2)
        ledger.record(3, account: "org-a")
        #expect(ledger.generation(of: "org-a") == 3)
        #expect(ledger.generation(of: "org-c") == 2)
    }
}
