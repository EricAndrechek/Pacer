import Foundation
import SwiftData
import Testing
@testable import PacerCore

private func makeContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: TokenSample.self, Account.self, AccountActivation.self,
        configurations: config
    )
}

private func at(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_780_000_000 + offset)
}

private func makeSample(_ when: Date) -> TokenSample {
    TokenSample(
        sampledAt: when,
        date: TokenSample.formatDate(when),
        model: "claude-opus-5",
        inputTokens: 1, outputTokens: 1,
        cacheReadTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0
    )
}

private func makeAccount(_ id: String) -> Account {
    Account(id: id, organizationId: id, displayName: id,
            isActive: true, firstSeenAt: at(0), lastSeenAt: at(0))
}

@Suite("Account backfill")
@ScanActor
struct AccountBackfillTests {

    @Test("one known account claims all unattributed history")
    func singleAccountBackfillsEverything() throws {
        let context = ModelContext(try makeContainer())
        context.insert(makeAccount("solo"))
        for i in 0..<5 { context.insert(makeSample(at(Double(i) * 100))) }
        try context.save()

        let result = try AccountBackfill.backfillIfUnambiguous(context: context, now: at(10_000))
        #expect(result?.samplesAttributed == 5)

        let samples = try context.fetch(FetchDescriptor<TokenSample>())
        #expect(samples.allSatisfy { $0.accountId == "solo" })
    }

    @Test("two accounts means no automatic backfill at all")
    func twoAccountsRefusesToGuess() throws {
        let context = ModelContext(try makeContainer())
        context.insert(makeAccount("work"))
        context.insert(makeAccount("personal"))
        for i in 0..<5 { context.insert(makeSample(at(Double(i) * 100))) }
        try context.save()

        let result = try AccountBackfill.backfillIfUnambiguous(context: context, now: at(10_000))
        #expect(result == nil)

        let samples = try context.fetch(FetchDescriptor<TokenSample>())
        #expect(samples.allSatisfy { $0.accountId == nil })
    }

    @Test("no accounts means nothing to backfill to")
    func noAccountsIsANoOp() throws {
        let context = ModelContext(try makeContainer())
        context.insert(makeSample(at(0)))
        try context.save()
        #expect(try AccountBackfill.backfillIfUnambiguous(context: context) == nil)
    }

    @Test("a manual assignment covers only its own range")
    func manualAssignmentIsRangeBounded() throws {
        let context = ModelContext(try makeContainer())
        for i in 0..<6 { context.insert(makeSample(at(Double(i) * 100))) }
        try context.save()

        // Everything strictly before t=300 is "work".
        let result = try AccountBackfill.assign(
            accountId: "work", from: nil, through: at(300),
            context: context, evidence: "test"
        )
        #expect(result.samplesAttributed == 3)

        let samples = try context.fetch(
            FetchDescriptor<TokenSample>(sortBy: [SortDescriptor(\.sampledAt)])
        )
        #expect(samples.map(\.accountId) == ["work", "work", "work", nil, nil, nil])
    }

    @Test("a backfill never overwrites an observed attribution")
    func observedAttributionWins() throws {
        let context = ModelContext(try makeContainer())
        let observed = makeSample(at(50))
        observed.accountId = "personal"   // as if stamped live at insert
        context.insert(observed)
        context.insert(makeSample(at(60)))
        try context.save()

        let result = try AccountBackfill.assign(
            accountId: "work", from: nil, through: at(1000),
            context: context, evidence: "test"
        )
        #expect(result.samplesAttributed == 1)

        let samples = try context.fetch(
            FetchDescriptor<TokenSample>(sortBy: [SortDescriptor(\.sampledAt)])
        )
        #expect(samples.map(\.accountId) == ["personal", "work"])
    }

    @Test("an assignment records the span even when it matches no rows")
    func emptyRangeStillRecordsTheSpan() throws {
        let context = ModelContext(try makeContainer())
        let result = try AccountBackfill.assign(
            accountId: "work", from: at(0), through: at(100),
            context: context, evidence: "test"
        )
        #expect(result.samplesAttributed == 0)
        let spans = try context.fetch(FetchDescriptor<AccountActivation>())
        #expect(spans.count == 1)
        #expect(spans[0].accountId == "work")
        #expect(spans[0].source == AccountActivation.sourceManual)
    }

    @Test("the unattributed summary reports the real count and range")
    func summaryDescribesWhatIsMissing() throws {
        let context = ModelContext(try makeContainer())
        for i in 0..<4 { context.insert(makeSample(at(Double(i) * 100))) }
        let done = makeSample(at(500))
        done.accountId = "work"
        context.insert(done)
        try context.save()

        let summary = try AccountBackfill.unattributedSummary(context: context)
        #expect(summary.count == 4)
        #expect(summary.earliest == at(0))
        #expect(summary.latest == at(300))
    }
}
