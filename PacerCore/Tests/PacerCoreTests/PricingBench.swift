import Foundation
import Testing
@testable import PacerCore

/// Per-sample pricing cost, in thread CPU time so a loaded machine doesn't
/// skew it. A full rebuild prices every sample about eight times (four
/// rollups, each with its per-account split), so this is the number that
/// decides how long a `costRecomputeVersion` bump takes.
/// Opt-in: `PACER_PRICING_BENCH=1 swift test --filter PricingBench`.
@Suite("Pricing bench", .enabled(if: ProcessInfo.processInfo.environment["PACER_PRICING_BENCH"] != nil))
struct PricingBench {
    static func cpu() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    @Test func perSampleCost() throws {
        let models = ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8",
                      "claude-opus-4-7", "claude-sonnet-5-5", "claude-fable-5", "claude-fable-5-1",
                      "claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5-20251001", "claude-haiku-5-5"]
        let snap = PricingTable.Snapshot(pricingByModel: Self.catalog())
        let ledger = snap.ledger
        let b = TokenBreakdown(inputTokens: 10, outputTokens: 500, cacheReadTokens: 80_000,
                               cacheCreation5mTokens: 1_000, cacheCreation1hTokens: 2_000)
        let n = 1_000_000
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        var sum = 0.0
        let t0 = Self.cpu()
        for i in 0..<n {
            sum += ledger.cost(model: models[i % models.count],
                               at: base.addingTimeInterval(Double(i)), breakdown: b).total
        }
        let ledgerNs = (Self.cpu() - t0) / Double(n) * 1e9
        // The old path's shape: catalog lookup + flat multiply.
        let t1 = Self.cpu()
        var sum2 = 0.0
        for i in 0..<n {
            if let p = snap.pricing(for: models[i % models.count]) {
                // Split up: Xcode 16's type checker times out on the one-liner.
                let input: Double = Double(b.inputTokens) * (p.inputCostPerToken ?? 0)
                let output: Double = Double(b.outputTokens) * (p.outputCostPerToken ?? 0)
                let read: Double = Double(b.cacheReadTokens) * (p.cacheReadInputTokenCost ?? 0)
                let w5m: Double = Double(b.cacheCreation5mTokens) * (p.cacheCreationInputTokenCost ?? 0)
                let w1h: Double = Double(b.cacheCreation1hTokens) * (p.cacheCreationInputTokenCostAbove1hr ?? 0)
                sum2 += input + output + read + w5m + w1h
            }
        }
        let flatNs = (Self.cpu() - t1) / Double(n) * 1e9
        print(String(format: "[bench] ledger %.0f ns/sample, flat lookup %.0f ns/sample (checksum %.2f / %.2f)",
                     ledgerNs, flatNs, sum, sum2))
    }

    /// `PACER_PRICING_BENCH_CATALOG` (a catalog cache copy), else the
    /// embedded snapshot.
    static func catalog() -> [String: LiteLLMModelPricing] {
        let url = ProcessInfo.processInfo.environment["PACER_PRICING_BENCH_CATALOG"]
            .map(URL.init(fileURLWithPath:))
            ?? Bundle.module.url(forResource: "litellm-pricing", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return PricingTable.decode(json: json)
    }
}
