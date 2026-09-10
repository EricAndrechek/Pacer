import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Not an assertion of behaviour — a measurement of how long the active-account
/// swap blocks, at the row counts a real machine reaches. Kept as a test so the
/// number is reproducible rather than a one-off note in a commit message.
@Suite("Swap cost", .disabled("benchmark — run explicitly"))
@MainActor
struct SwapCostBench {

    @Test("restoring an account's window costs what?")
    func measureRestore() throws {
        let container = try ModelContainer(
            for: RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            AccountUsageArchive.self, Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        // Matches the maintainer's machine: ~3,077 rows/day over a 35-day
        // window once the bound is applied.
        let n = 107_705
        let now = Date()
        for i in 0..<n {
            context.insert(AccountUsageArchive(
                accountId: "incoming",
                kind: AccountUsageArchive.kindRateLimit,
                sampledAt: now.addingTimeInterval(-Double(i) * 28),
                window: RateLimitWindowName.fiveHour,
                usedPercentage: Double(i % 100), resetsAt: nil,
                source: RateLimitSource.oauth))
        }
        try context.save()

        let started = Date()
        let cutoff = now.addingTimeInterval(-OAuthPoller.liveWindowDays * 86_400)
        let archived = try context.fetch(FetchDescriptor<AccountUsageArchive>(
            predicate: #Predicate { $0.accountId == "incoming" && $0.sampledAt >= cutoff }))
        for a in archived {
            context.insert(RateLimitSample(
                sampledAt: a.sampledAt, window: a.window ?? RateLimitWindowName.fiveHour,
                usedPercentage: a.usedPercentage ?? 0, resetsAt: a.resetsAt,
                source: a.source, accountId: "incoming"))
            context.delete(a)
        }
        try context.save()
        let elapsed = Date().timeIntervalSince(started)
        print("SWAP-BENCH restored \(archived.count) row(s) in \(String(format: "%.2f", elapsed))s")
        #expect(elapsed >= 0)
    }
}
