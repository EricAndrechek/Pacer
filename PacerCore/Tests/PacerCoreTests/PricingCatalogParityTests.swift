import Foundation
import Testing
@testable import PacerCore

/// #469: `bin/price-catalog-sync.py` must merge the catalogs exactly as the
/// app does, or the price list it publishes would say something no Mac would
/// have computed. This runs the script's `templates` command and the app's own
/// path (`PricingTable.decode` → `reconcile` → `decode` →
/// `PriceLedger.catalogTemplates`) over the same payloads and requires the
/// same records: identity, tier, the five rates, which were derived, the fast
/// and regional multipliers, and the source.
///
/// The fixtures cover the edge cases (consensus overriding LiteLLM, a split
/// vote, gap-fill from each secondary, both Catwalk shapes, every partner-cloud
/// spelling, rows the decoder drops); the bundled LiteLLM snapshot covers
/// breadth. `PRICE_SYNC_PARITY_DIR`, a directory holding live
/// `litellm.json`, `models-dev.json` and `catwalk.json`, adds a run over
/// those.
@Suite("Price catalog sync parity")
struct PricingCatalogParityTests {

    static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let repo = here.appendingPathComponent("../../..").standardizedFileURL
    static let script = repo.appendingPathComponent("bin/price-catalog-sync.py")
    static let fixtures = here.appendingPathComponent("PriceSyncFixtures")
    static let snapshot = repo.appendingPathComponent("PacerCore/Sources/PacerCore/Resources/litellm-pricing.json")

    /// The script's records for these payloads, decoded the way the app
    /// decodes the published list.
    static func script(litellm: URL, modelsDev: URL, catwalk: URL) throws -> [PriceRecordValue] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", script.path, "templates", "--litellm", litellm.path,
                       "--models-dev", modelsDev.path, "--catwalk", catwalk.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "parity", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: errData, as: UTF8.self)])
        }
        let rows = try JSONDecoder().decode([CuratedPriceHistory.File.CatalogRow].self, from: data)
        return try CuratedPriceHistory.decodeCatalog(rows)
    }

    /// What `PricingTable.refresh` and the ledger make of the same payloads,
    /// minus the built-in fallback rows, which stay in the app.
    static func app(litellm: URL, modelsDev: URL, catwalk: URL) throws -> [PriceRecordValue] {
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: litellm)) as? [String: Any])
        let lite = PricingTable.decode(json: raw)
        let merged = PricingTable.reconcile(
            secondaries: [
                ("models.dev", ModelsDevCatalog.anthropicEntries(from: try Data(contentsOf: modelsDev))),
                ("catwalk", CatwalkCatalog.anthropicEntries(from: try Data(contentsOf: catwalk))),
            ],
            into: raw, covered: lite)
        // Through the cache file's round trip, as the app reads it next launch.
        let cached = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        let json = try #require(try JSONSerialization.jsonObject(with: cached) as? [String: Any])
        return PriceLedger.catalogTemplates(PricingTable.decode(json: json)).filter { $0.source != .fallback }
    }

    struct Slot: Hashable, CustomStringConvertible {
        let key: CanonicalModelID
        let speed: PriceSpeed
        let tier: Int64
        var description: String { "\(key) \(speed.rawValue) >\(tier)" }
    }

    static func compare(litellm: URL, modelsDev: URL, catwalk: URL) throws -> Int {
        let fromScript = try script(litellm: litellm, modelsDev: modelsDev, catwalk: catwalk)
        let fromApp = try app(litellm: litellm, modelsDev: modelsDev, catwalk: catwalk)
        func bySlot(_ rs: [PriceRecordValue]) -> [Slot: PriceRecordValue] {
            Dictionary(rs.map { (Slot(key: $0.key, speed: $0.speed, tier: $0.tierAbovePromptTokens), $0) },
                       uniquingKeysWith: { a, _ in a })
        }
        let a = bySlot(fromScript), b = bySlot(fromApp)
        #expect(fromScript.count == a.count, "the script listed a slot twice")
        let onlyScript = Set(a.keys).subtracting(b.keys).map(\.description).sorted()
        let onlyApp = Set(b.keys).subtracting(a.keys).map(\.description).sorted()
        #expect(Set(a.keys) == Set(b.keys), "only the script: \(onlyScript); only the app: \(onlyApp)")
        for (slot, x) in a {
            guard let y = b[slot] else { continue }
            #expect(x.rates.sameNumbers(as: y.rates), "\(slot): \(x.rates.perMTokSummary) vs \(y.rates.perMTokSummary)")
            #expect(x.rates.derived == y.rates.derived, "\(slot): derived")
            #expect(x.fastMultiplier == y.fastMultiplier && x.regionalMultiplier == y.regionalMultiplier, "\(slot): multipliers")
            #expect(x.source == y.source, "\(slot): source \(x.source) vs \(y.source)")
        }
        return a.count
    }

    @Test func theFixturesMergeAlike() throws {
        let n = try Self.compare(litellm: Self.fixtures.appendingPathComponent("litellm.json"),
                                 modelsDev: Self.fixtures.appendingPathComponent("models-dev.json"),
                                 catwalk: Self.fixtures.appendingPathComponent("catwalk.json"))
        #expect(n >= 15)
    }

    @Test func theBundledLiteLLMSnapshotMergesAlike() throws {
        let n = try Self.compare(litellm: Self.snapshot,
                                 modelsDev: Self.fixtures.appendingPathComponent("models-dev.json"),
                                 catwalk: Self.fixtures.appendingPathComponent("catwalk.json"))
        #expect(n > 100)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRICE_SYNC_PARITY_DIR"] != nil))
    func liveCatalogsMergeAlike() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PRICE_SYNC_PARITY_DIR"]!)
        let n = try Self.compare(litellm: dir.appendingPathComponent("litellm.json"),
                                 modelsDev: dir.appendingPathComponent("models-dev.json"),
                                 catwalk: dir.appendingPathComponent("catwalk.json"))
        #expect(n > 100)
    }
}
