import Foundation
import Testing
@testable import PacerCore

/// #298: the curated price history as shipped — dated facts no catalog holds.
@Suite("Curated price history")
struct CuratedPriceHistoryTests {

    static let curated = try! CuratedPriceHistory.bundled()

    static func day(_ s: String) -> Date { try! CuratedPriceHistory.date(s) }
    static let noon: TimeInterval = 12 * 3600

    /// A catalog that disagrees with the curated file, the way the catalogs
    /// actually did: Sonnet 5 at $3/$15 and Sonnet 5.5 reading at $0.20,
    /// both first seen on their launch days.
    static func ledger(extra: [PriceRecordValue] = []) -> PriceLedger {
        func cat(_ model: String, _ i: Double, _ o: Double, read: Double, from: String) -> PriceRecordValue {
            PriceRecordValue(
                key: CanonicalModelID(model: model),
                rates: PriceRates(input: i / 1e6, output: o / 1e6, cacheRead: read / 1e6,
                                  cacheWrite5m: i * 1.25 / 1e6, cacheWrite1h: i * 2 / 1e6),
                effectiveFrom: day(from), source: .litellm)
        }
        return PriceLedger(records: curated.records + [
            cat("claude-sonnet-5", 3, 15, read: 0.3, from: "2026-06-30"),
            cat("claude-sonnet-5-5", 2, 10, read: 0.2, from: "2026-09-28"),
        ] + extra)
    }

    static let mtok = TokenBreakdown(inputTokens: 1_000_000)
    static let mtokOut = TokenBreakdown(outputTokens: 1_000_000)
    static let mtokRead = TokenBreakdown(cacheReadTokens: 1_000_000)

    func cost(_ model: String, _ date: String, _ b: TokenBreakdown, speed: PriceSpeed = .standard,
              ledger: PriceLedger = Self.ledger()) -> SampleCost {
        ledger.cost(model: model, at: Self.day(date).addingTimeInterval(Self.noon), speed: speed, breakdown: b)
    }

    @Test func theFileIsReviewedAndCurrent() {
        #expect(Self.curated.records.count >= 25)
        #expect(Self.curated.records.allSatisfy { $0.curated && $0.sourceURL != nil && $0.note != nil })
        #expect(Self.curated.asOf >= Self.day("2026-10-21"))
    }

    @Test func sonnet5IsTwoAndTenAcrossItsWholeWindow() {
        // Launch, the introductory window, after the rise that never came,
        // and today — catalog's $3/$15 notwithstanding.
        for date in ["2026-06-30", "2026-07-01", "2026-08-31", "2026-09-01", "2026-10-21"] {
            #expect(abs(cost("claude-sonnet-5", date, Self.mtok).total - 2) < 1e-9, "\(date)")
            #expect(abs(cost("claude-sonnet-5", date, Self.mtokOut).total - 10) < 1e-9, "\(date)")
        }
        #expect(cost("claude-sonnet-5", "2026-07-01", Self.mtok).flags.isEmpty)
    }

    /// The release notes (Oct 7): "lowered the price of prompt cache reads on
    /// Claude Sonnet 5.5 from $0.20 to $0.10". An earlier curated file had 0.05x
    /// throughout and was wrong for the first nine days.
    @Test func sonnet55CacheReadWas20CentsUntilOct7ThenTen() {
        for date in ["2026-09-28", "2026-10-01", "2026-10-06"] {
            #expect(abs(cost("claude-sonnet-5-5", date, Self.mtokRead).total - 0.20) < 1e-9, "\(date)")
        }
        for date in ["2026-10-07", "2026-10-10", "2026-10-21"] {
            #expect(abs(cost("claude-sonnet-5-5", date, Self.mtokRead).total - 0.10) < 1e-9, "\(date)")
        }
        // Nothing else moved: $2 in, $10 out, $2.50 / $4 writes, before and after.
        for date in ["2026-10-01", "2026-10-10"] {
            #expect(abs(cost("claude-sonnet-5-5", date, Self.mtok).total - 2) < 1e-9)
            #expect(abs(cost("claude-sonnet-5-5", date, Self.mtokOut).total - 10) < 1e-9)
            #expect(abs(cost("claude-sonnet-5-5", date, TokenBreakdown(cacheCreation5mTokens: 1_000_000)).total - 2.5) < 1e-9)
            #expect(abs(cost("claude-sonnet-5-5", date, TokenBreakdown(cacheCreation1hTokens: 1_000_000)).total - 4) < 1e-9)
        }
    }

    @Test func opus47FastModeRanMay12ToJul24() {
        #expect(abs(cost("claude-opus-4-7", "2026-06-01", Self.mtok, speed: .fast).total - 30) < 1e-9)
        #expect(abs(cost("claude-opus-4-7", "2026-05-12", Self.mtokOut, speed: .fast).total - 150) < 1e-9)
        for date in ["2026-04-20", "2026-05-11", "2026-07-24", "2026-08-01"] {
            #expect(cost("claude-opus-4-7", date, Self.mtok, speed: .fast).flags.contains(.unpricedPremium), "\(date)")
        }
        #expect(abs(cost("claude-opus-4-7", "2026-08-01", Self.mtok).total - 5) < 1e-9)
    }

    @Test func opus46FastModeRanFeb7ToJun29WithAnOver200kPremiumAtLaunch() {
        let long = TokenBreakdown(inputTokens: 250_000)
        // Not yet available / removed.
        #expect(cost("claude-opus-4-6", "2026-02-06", Self.mtok, speed: .fast).flags.contains(.unpricedPremium))
        #expect(cost("claude-opus-4-6", "2026-06-29", Self.mtok, speed: .fast).flags.contains(.unpricedPremium))
        #expect(!cost("claude-opus-4-6", "2026-06-28", Self.mtok, speed: .fast).flags.contains(.unpricedPremium))
        #expect(abs(cost("claude-opus-4-6", "2026-06-29", Self.mtok).total - 5) < 1e-9)
        // Launch: $30/$150, and $60/$225 over 200k.
        #expect(abs(cost("claude-opus-4-6", "2026-02-10", TokenBreakdown(inputTokens: 100_000), speed: .fast).total - 3) < 1e-9)
        #expect(abs(cost("claude-opus-4-6", "2026-02-10", Self.mtokOut, speed: .fast).total - 150) < 1e-9)
        #expect(abs(cost("claude-opus-4-6", "2026-02-10", long, speed: .fast).total - 250_000 * 60e-6) < 1e-9)
        #expect(abs(cost("claude-opus-4-6", "2026-02-10", TokenBreakdown(inputTokens: 100, outputTokens: 1_000_000, cacheReadTokens: 250_000), speed: .fast).total
                    - (100 * 60e-6 + 225 + 250_000 * 6e-6)) < 1e-9)
        // Premium dropped: over 200k is $30 (not 6x the still-premium standard tier).
        #expect(abs(cost("claude-opus-4-6", "2026-03-01", long, speed: .fast).total - 250_000 * 30e-6) < 1e-9)
        #expect(abs(cost("claude-opus-4-6", "2026-03-01", long).total - 250_000 * 10e-6) < 1e-9)
        // Small prompts are not caught by the upper-tier fast record.
        #expect(abs(cost("claude-opus-4-6", "2026-02-10", TokenBreakdown(inputTokens: 1000), speed: .fast).total - 1000 * 30e-6) < 1e-9)
        // After the premium window: plain 6x.
        #expect(abs(cost("claude-opus-4-6", "2026-05-01", long, speed: .fast).total - 250_000 * 30e-6) < 1e-9)
    }

    @Test func sonnet4LongContextTierRanItsBetaOnly() {
        let long = TokenBreakdown(inputTokens: 250_000)
        // Sonnet 4: 1M beta from 2025-08-12 to 2026-04-30.
        #expect(abs(cost("claude-sonnet-4", "2025-07-01", long).total - 250_000 * 3e-6) < 1e-9)
        #expect(abs(cost("claude-sonnet-4", "2025-08-12", long).total - 250_000 * 6e-6) < 1e-9)
        #expect(abs(cost("claude-sonnet-4", "2026-04-29", long).total - 250_000 * 6e-6) < 1e-9)
        #expect(abs(cost("claude-sonnet-4", "2026-05-01", long).total - 250_000 * 3e-6) < 1e-9)
        // Sonnet 4.5: premium ended 2026-04-30 too.
        #expect(abs(cost("claude-sonnet-4-5", "2026-04-29", long).total - 250_000 * 6e-6) < 1e-9)
        #expect(abs(cost("claude-sonnet-4-5", "2026-05-01", long).total - 250_000 * 3e-6) < 1e-9)
    }

    @Test func mythosPreviewIs25And125WithDerivedCacheRates() {
        #expect(abs(cost("claude-mythos-preview", "2026-04-07", Self.mtok).total - 25) < 1e-9)
        #expect(abs(cost("claude-mythos-preview", "2026-05-01", Self.mtokOut).total - 125) < 1e-9)
        #expect(abs(cost("claude-mythos-preview", "2026-05-01", TokenBreakdown(cacheCreation5mTokens: 1_000_000)).total - 31.25) < 1e-9)
        #expect(abs(cost("claude-mythos-preview", "2026-05-01", TokenBreakdown(cacheCreation1hTokens: 1_000_000)).total - 50) < 1e-9)
        #expect(abs(cost("claude-mythos-preview", "2026-05-01", Self.mtokRead).total - 2.5) < 1e-9)
        let r = Self.curated.records.first { $0.key.model == "claude-mythos-preview" }!
        #expect(r.note?.contains("DERIVED") == true)
        #expect(r.sourceURL == "https://www.anthropic.com/glasswing")
    }

    @Test func retirementsAndOneHourWritesAreRecorded() {
        func rec(_ m: String) -> PriceRecordValue { Self.curated.records.first { $0.key.model == m && $0.tierAbovePromptTokens == 0 }! }
        #expect(rec("claude-3-5-sonnet").effectiveTo == Self.day("2025-10-28"))
        #expect(rec("claude-3-7-sonnet").effectiveTo == Self.day("2026-02-19"))
        #expect(rec("claude-3-5-haiku").note?.contains("2026-02-19") == true)
        #expect(rec("claude-opus-4").note?.contains("2026-06-15") == true)
        #expect(rec("claude-sonnet-4").note?.contains("2026-06-15") == true)
        #expect(rec("claude-opus-4-1").note?.contains("2026-08-05") == true)
        for m in ["claude-3-5-haiku", "claude-3-5-sonnet", "claude-3-7-sonnet"] {
            #expect(rec(m).note?.contains("2025-05-22") == true, "\(m)")
        }
    }

    @Test func cacheReadMultipliersMatchThePage() {
        // 0.025x on Fable/Mythos 5.1, 0.05x on Opus/Sonnet 5.5, 0.1x elsewhere.
        let cases: [(String, Double)] = [
            ("claude-fable-5-1", 0.025), ("claude-mythos-5-1", 0.025), ("claude-opus-5-5", 0.05),
            ("claude-sonnet-5-5", 0.05), ("claude-opus-5", 0.1), ("claude-fable-5", 0.1),
            ("claude-haiku-4-5", 0.1), ("claude-sonnet-4-6", 0.1),
        ]
        for (model, m) in cases {
            let r = cost(model, "2026-10-21", Self.mtokRead).total / cost(model, "2026-10-21", Self.mtok).total
            #expect(abs(r - m) < 1e-12, "\(model)")
        }
    }

    @Test func opus46LongContextPremiumEndedAndItsFastModeWasSixTimes() {
        let long = TokenBreakdown(inputTokens: 250_000)
        #expect(abs(cost("claude-opus-4-6", "2026-03-01", long).total - 250_000 * 10e-6) < 1e-9)
        #expect(abs(cost("claude-opus-4-6", "2026-04-10", long).total - 250_000 * 5e-6) < 1e-9)
        #expect(abs(cost("claude-opus-4-6", "2026-04-10", Self.mtok, speed: .fast).total - 30) < 1e-9)
        #expect(cost("claude-opus-4-6", "2026-09-10", Self.mtok, speed: .fast).flags.contains(.unpricedPremium))
    }

    @Test func fastModeOnTheModelsThatHaveIt() {
        #expect(abs(cost("claude-opus-5-5", "2026-10-01", Self.mtok, speed: .fast).total - 8) < 1e-9)
        #expect(abs(cost("claude-opus-5", "2026-10-01", Self.mtokOut, speed: .fast).total - 50) < 1e-9)
        #expect(abs(cost("claude-opus-4-8", "2026-10-01", Self.mtok, speed: .fast).total - 10) < 1e-9)
        #expect(cost("claude-sonnet-5-5", "2026-10-01", Self.mtok, speed: .fast).flags.contains(.unpricedPremium))
    }

    @Test func haiku55IsTieredAtOneHundredThousand() {
        let small = TokenBreakdown(inputTokens: 100_000), big = TokenBreakdown(inputTokens: 100_001)
        #expect(abs(cost("claude-haiku-5-5", "2026-10-15", small).total - 0.01) < 1e-9)
        #expect(abs(cost("claude-haiku-5-5", "2026-10-15", big).total - 100_001 * 0.5e-6) < 1e-9)
    }

    @Test func aCatalogChangeAfterTheReviewStillGetsThrough() {
        let rise = PriceRecordValue(
            key: CanonicalModelID(model: "claude-sonnet-5"),
            rates: PriceRates(input: 3e-6, output: 15e-6, cacheRead: 0.3e-6,
                              cacheWrite5m: 3.75e-6, cacheWrite1h: 6e-6),
            effectiveFrom: Self.day("2026-11-15"), source: .litellm)
        let ledger = Self.ledger(extra: [rise])
        #expect(abs(cost("claude-sonnet-5", "2026-11-01", Self.mtok, ledger: ledger).total - 2) < 1e-9)
        #expect(abs(cost("claude-sonnet-5", "2026-11-20", Self.mtok, ledger: ledger).total - 3) < 1e-9)
    }

    /// Every model a real store has used (as of this file's review), with the
    /// day its first sample was recorded, is covered by a curated record
    /// from that day — so none of its history is priced outside a window.
    @Test func everyModelInUseIsCoveredFromItsFirstSample() {
        let firstSamples: [(String, String)] = [
            ("claude-opus-4-6", "2026-04-01"), ("claude-haiku-4-5-20251001", "2026-04-01"),
            ("claude-sonnet-4-6", "2026-04-14"), ("claude-opus-4-7", "2026-04-17"),
            ("claude-opus-4-8", "2026-05-28"), ("claude-fable-5", "2026-06-09"),
            ("claude-sonnet-5", "2026-07-01"), ("claude-opus-5", "2026-07-27"),
            ("claude-fable-5-1", "2026-09-01"), ("claude-opus-5-5", "2026-09-23"),
            ("claude-sonnet-5-5", "2026-09-30"), ("claude-haiku-5-5", "2026-10-14"),
        ]
        let curatedOnly = PriceLedger(records: Self.curated.records)
        for (model, first) in firstSamples {
            let c = cost(model, first, Self.mtok, ledger: curatedOnly)
            #expect(c.total > 0 && c.flags.isEmpty, "\(model) on \(first): \(c.flags)")
            #expect(c.pricedBy.first?.hasPrefix("curated|") == true, "\(model)")
        }
    }
}
