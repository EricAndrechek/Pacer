import Foundation
import Testing
@testable import PacerCore

@Suite("UsageHints.compute")
struct UsageHintsTests {

    private func t(
        _ model: String,
        cost: Double = 0,
        input: Int64 = 0,
        output: Int64 = 0,
        cacheRead: Int64 = 0
    ) -> UsageHints.ModelTotals {
        UsageHints.ModelTotals(
            model: model,
            costUSD: cost,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead
        )
    }

    @Test func noHintsForEmptyData() {
        let hints = UsageHints.compute(todayByModel: [], thisWeekByModel: [])
        #expect(hints.isEmpty)
    }

    @Test func heavyPremiumFiresAtThreshold() {
        // 80% Opus, $10 today, Sonnet used this week → fire.
        let today = [
            t("claude-opus-4-7", cost: 8),
            t("claude-sonnet-4-6", cost: 2)
        ]
        let week = [t("claude-sonnet-4-6", input: 1000)]
        let hints = UsageHints.compute(todayByModel: today, thisWeekByModel: week)
        if case .heavyPremiumShare(let pct, let cost) = hints.first {
            #expect(abs(pct - 0.8) < 1e-9)
            #expect(abs(cost - 10) < 1e-9)
        } else {
            Issue.record("expected heavyPremiumShare; got \(hints)")
        }
    }

    @Test func heavyPremiumFiresForFableAndMythos() {
        // Premium families combine: Fable + Opus + Mythos together
        // carry 80% of a $20 day. A pure-Fable day used to slip past
        // the old "opus"-substring filter entirely.
        let today = [
            t("claude-fable-5", cost: 9),
            t("claude-opus-4-8", cost: 4),
            t("claude-mythos-5", cost: 3),
            t("claude-sonnet-4-6", cost: 4)
        ]
        let week = [t("claude-sonnet-4-6", input: 1000)]
        let hints = UsageHints.compute(todayByModel: today, thisWeekByModel: week)
        if case .heavyPremiumShare(let pct, let cost) = hints.first {
            #expect(abs(pct - 0.8) < 1e-9)
            #expect(abs(cost - 20) < 1e-9)
        } else {
            Issue.record("expected heavyPremiumShare; got \(hints)")
        }
    }

    @Test func heavyPremiumSuppressedWhenSonnetNotUsedThisWeek() {
        // User never tried Sonnet → don't recommend it.
        let today = [
            t("claude-opus-4-7", cost: 8),
            t("claude-sonnet-4-6", cost: 2)
        ]
        let hints = UsageHints.compute(todayByModel: today, thisWeekByModel: [])
        #expect(hints.isEmpty)
    }

    @Test func heavyPremiumSuppressedWhenCostTooSmall() {
        // Total cost is below the $5 floor; not worth surfacing.
        let today = [
            t("claude-opus-4-7", cost: 1.5),
            t("claude-sonnet-4-6", cost: 0.5)
        ]
        let week = [t("claude-sonnet-4-6", input: 1000)]
        let hints = UsageHints.compute(todayByModel: today, thisWeekByModel: week)
        #expect(hints.isEmpty)
    }

    @Test func heavyPremiumSuppressedBelowShareThreshold() {
        // 60% Opus — below the 70% threshold.
        let today = [
            t("claude-opus-4-7", cost: 6),
            t("claude-sonnet-4-6", cost: 4)
        ]
        let week = [t("claude-sonnet-4-6", input: 1000)]
        let hints = UsageHints.compute(todayByModel: today, thisWeekByModel: week)
        #expect(hints.isEmpty)
    }

    @Test func lowCacheHitRateFiresWhenBelow50Percent() {
        // 40% cache hit rate, 200K tokens — fire.
        let today = [
            t("claude-sonnet-4-6", input: 60_000, output: 40_000, cacheRead: 40_000)
        ]
        let hints = UsageHints.compute(todayByModel: today, thisWeekByModel: today)
        if case .lowCacheHitRate(let ratio, let tokens) = hints.first {
            #expect(abs(ratio - 0.4) < 1e-9)
            #expect(tokens == 140_000)
        } else {
            Issue.record("expected lowCacheHitRate; got \(hints)")
        }
    }

    @Test func lowCacheHitSuppressedBelowTokenFloor() {
        // Same ratio but very few tokens — too noisy to surface.
        let today = [
            t("claude-sonnet-4-6", input: 600, output: 400, cacheRead: 400)
        ]
        let hints = UsageHints.compute(todayByModel: today, thisWeekByModel: today)
        #expect(hints.isEmpty)
    }

    @Test func bothHintsCanFireTogether() {
        // Heavy Opus AND low cache.
        let today = [
            t("claude-opus-4-7", cost: 8, input: 80_000, output: 20_000, cacheRead: 30_000),
            t("claude-sonnet-4-6", cost: 2, input: 4_000, output: 1_000, cacheRead: 2_000)
        ]
        let week = [t("claude-sonnet-4-6", input: 1000)]
        let hints = UsageHints.compute(todayByModel: today, thisWeekByModel: week)
        #expect(hints.count == 2)
    }
}
