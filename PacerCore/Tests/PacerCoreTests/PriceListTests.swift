import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// #469: the price list — catalog prices merged and dated once on our side
/// (`bin/price-catalog-sync.py`), published in the price history's `catalog`
/// section, read by the app as its primary catalog source.
@Suite("Price list", .serialized)
struct PriceListTests {

    static func day(_ s: String) -> Date { try! CuratedPriceHistory.date(s) }

    /// The bundled file as JSON, so a test can add a `catalog` section to the
    /// real curated records.
    static func bundledJSON() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/PacerCore/Resources/price-history.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func row(_ model: String, provider: String = "anthropic", region: String = "global",
                    from: String, to: String? = nil, input: Double, read: Double? = nil,
                    tier: Int? = nil, derived: [String]? = nil, regional: Double? = nil,
                    fast: Double? = nil, source: String = "litellm") -> [String: Any] {
        var r: [String: Any] = [
            "model": model, "provider": provider, "region": region,
            "effectiveFrom": from, "effectiveTo": to.map { $0 as Any } ?? NSNull(),
            "perMTok": ["input": input, "output": input * 5, "cacheWrite5m": input * 1.25,
                        "cacheWrite1h": input * 2, "cacheRead": read ?? input * 0.1],
            "source": source,
        ]
        if let tier { r["tierAbovePromptTokens"] = tier }
        if let derived { r["derived"] = derived }
        if let regional { r["regionalMultiplier"] = regional }
        if let fast { r["fastMultiplier"] = fast }
        return r
    }

    static func file(base: [String: Any]? = nil, rows: [[String: Any]],
                     changedAt: String = "2026-11-25T18:00:00Z",
                     checkedAt: String = "2026-11-25T18:00:00Z") throws -> Data {
        var doc = try base ?? bundledJSON()
        doc["catalog"] = ["changedAt": changedAt, "checkedAt": checkedAt, "records": rows]
        return try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    }

    static let mtok = TokenBreakdown(inputTokens: 1_000_000)
    static let mtokRead = TokenBreakdown(cacheReadTokens: 1_000_000)

    // MARK: Decoding

    @Test func theCatalogSectionDecodesAsListRecords() throws {
        let data = try Self.file(rows: [
            Self.row("claude-sonnet-4-5", provider: "bedrock", region: "us", from: "2026-11-25T18:00:00Z",
                     input: 3.3, derived: ["cacheWrite1h"], regional: 1.1),
            Self.row("claude-haiku-5-5", from: "2026-10-07", input: 0.5, tier: 100_000,
                     derived: ["cacheWrite5m", "cacheWrite1h"], source: "models.dev"),
        ])
        let h = try CuratedPriceHistory.decode(data)
        #expect(h.records.count == (try CuratedPriceHistory.bundled()).records.count)
        #expect(h.catalog.count == 2)
        #expect(h.catalog.allSatisfy { $0.fromPriceList && !$0.curated && $0.id.hasPrefix("list|") })
        #expect(h.catalogChangedAt == Self.day("2026-11-25T18:00:00Z"))
        let bedrock = try #require(h.catalog.first { $0.key.provider == .bedrock })
        #expect(bedrock.key == CanonicalModelID(model: "claude-sonnet-4-5", provider: .bedrock, region: .us))
        #expect(abs(bedrock.rates.input - 3.3e-6) < 1e-15)
        #expect(bedrock.rates.derived == .cacheWrite1h)
        #expect(bedrock.regionalMultiplier == 1.1 && bedrock.source == .litellm)
        let haiku = try #require(h.catalog.first { $0.key.model == "claude-haiku-5-5" })
        #expect(haiku.tierAbovePromptTokens == 100_000 && haiku.source == .modelsDev)
        #expect(haiku.rates.derived == [.cacheWrite5m, .cacheWrite1h])
    }

    @Test func aRowThisVersionCannotKeyIsSkippedButBadNumbersRejectTheFile() throws {
        let ok = try CuratedPriceHistory.decode(try Self.file(rows: [
            Self.row("claude-x", from: "2026-11-25", input: 1),
            Self.row("claude-x", provider: "someday-cloud", from: "2026-11-25", input: 1),
            Self.row("claude-y", from: "2026-11-25", input: 1, source: "a-new-catalog"),
            Self.row("claude-z", from: "2026-11-25", input: 1, source: "curated"),
        ]))
        #expect(ok.catalog.map(\.key.model).sorted() == ["claude-x", "claude-y", "claude-z"])
        // Provenance only: an unknown source, or one claiming to be curated,
        // is a catalog price.
        #expect(ok.catalog.allSatisfy { $0.source == .litellm })

        for bad in [
            [Self.row("claude-x", from: "2026-11-25", input: -1)],
            [Self.row("claude-x", from: "2026-11-25", to: "2026-11-24", input: 1)],
            [Self.row("claude-x", from: "not a date", input: 1)],
            [Self.row("claude-x", from: "2026-11-25", input: 1), Self.row("claude-x", from: "2026-11-25", input: 2)],
        ] {
            #expect(throws: CuratedPriceHistory.DecodeError.self) { try CuratedPriceHistory.decode(try Self.file(rows: bad)) }
        }
        var doc = try Self.bundledJSON()
        doc["catalog"] = ["changedAt": "2026-11-25", "records": []]   // no checkedAt
        #expect(throws: (any Error).self) {
            try CuratedPriceHistory.decode(try JSONSerialization.data(withJSONObject: doc))
        }
    }

    // MARK: 0.9.4 and earlier

    /// The new file is read by 0.8.0 through 0.9.4 exactly as before: their
    /// decoder (frozen below) ignores the `catalog` key and returns the same
    /// curated records, so their prices do not move and their copy is not
    /// rejected.
    @Test func theDecoderOf094ReadsTheNewFileAsBefore() throws {
        let plain = try JSONSerialization.data(withJSONObject: try Self.bundledJSON(), options: [.sortedKeys])
        let withList = try Self.file(rows: [
            Self.row("claude-sonnet-4-5", from: "2025-09-29", input: 3, regional: 1.1),
            Self.row("claude-sonnet-4-5", provider: "vertex", from: "2026-11-25T18:00:00Z", input: 3),
        ])
        let legacyPlain = try LegacyPriceHistoryDecoder.decode(plain)
        let legacyNew = try LegacyPriceHistoryDecoder.decode(withList)
        #expect(legacyNew == legacyPlain)
        #expect(legacyNew.records == (try CuratedPriceHistory.decode(withList)).records)
        #expect(legacyNew.asOf == (try CuratedPriceHistory.decode(withList)).asOf)
        // And the site's real copy, whatever the job has put in it by now.
        let site = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../site/public/price-history.json")
        if let data = try? Data(contentsOf: site) {
            let legacy = try LegacyPriceHistoryDecoder.decode(data)
            #expect(legacy.records == (try CuratedPriceHistory.decode(data)).records)
        }
    }

    // MARK: Which copy

    @Test func eachPartComesFromTheCopyThatHasItNewer() throws {
        let bundled = CuratedPriceHistory(asOf: Self.day("2026-12-01"), records: [])
        let list = [PriceRecordValue(
            id: "list|claude-x|anthropic|global|standard|0|0", key: CanonicalModelID(model: "claude-x"),
            rates: PriceRates(input: 1e-6, output: 5e-6, cacheRead: 1e-7, cacheWrite5m: 1.25e-6, cacheWrite1h: 2e-6),
            effectiveFrom: .distantPast, source: .litellm)]
        let cached = CuratedPriceHistory(asOf: Self.day("2026-11-11"), records: [], catalog: list,
                                         catalogChangedAt: Self.day("2026-11-25"),
                                         catalogCheckedAt: Self.day("2026-11-26"))
        let m = CuratedPriceHistory.merged(bundled, cached)
        #expect(m.asOf == Self.day("2026-12-01"))   // the release's curated part
        #expect(m.catalog == list)                  // the download's price list
        #expect(m.catalogCheckedAt == Self.day("2026-11-26"))
        #expect(CuratedPriceHistory.merged(cached, bundled) == m)
    }

    @Test func aDownloadIsCachedOnlyWhenItBringsSomething() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pricelist-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("price-history.cache.json")
        let suite = "pricelist.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        func serve(_ data: Data) async -> Bool {
            PriceListStub.serve(data)
            return await CuratedPriceHistory.refresh(urlSession: PriceListStub.session(), cacheURL: cache, store: store)
        }
        var old = try Self.bundledJSON()
        old["asOf"] = "2026-01-01"
        // An older curated part and no list: nothing to bring.
        #expect(!(await serve(try JSONSerialization.data(withJSONObject: old))))
        // An older curated part with a list: cached for the list, and `load`
        // still takes the curated part from the bundled copy.
        #expect(await serve(try Self.file(base: old, rows: [Self.row("claude-x", from: "2026-11-25", input: 1)])))
        let loaded = CuratedPriceHistory.load(cacheURL: cache)
        #expect(loaded.asOf == (try CuratedPriceHistory.bundled()).asOf)
        #expect(loaded.catalog.count == 1)
        // A list older than the cached one never replaces it.
        #expect(!(await serve(try Self.file(rows: [], changedAt: "2026-11-01", checkedAt: "2026-11-01"))))
        #expect(CuratedPriceHistory.load(cacheURL: cache).catalog.count == 1)
        // The same list re-confirmed later (a heartbeat) is cached.
        #expect(await serve(try Self.file(base: old, rows: [Self.row("claude-x", from: "2026-11-25", input: 1)],
                                          checkedAt: "2026-12-02T00:00:00Z")))
        #expect(CuratedPriceHistory.load(cacheURL: cache).catalogCheckedAt == Self.day("2026-12-02T00:00:00Z"))
    }

    // MARK: Precedence

    static func local(_ model: String, input: Double, read: Double? = nil, from: Date, to: Date? = nil) -> PriceRecordValue {
        PriceRecordValue(key: CanonicalModelID(model: model), rates: PriceLedgerTests.rates(input, read: read),
                         effectiveFrom: from, effectiveTo: to, source: .litellm)
    }

    static func listed(_ model: String, input: Double, read: Double? = nil, from: Date, to: Date? = nil) -> PriceRecordValue {
        let key = CanonicalModelID(model: model)
        return PriceRecordValue(
            id: PriceRecordValue.makeId(origin: .list, key: key, speed: .standard, tier: 0, from: from),
            key: key, rates: PriceLedgerTests.rates(input, read: read),
            effectiveFrom: from, effectiveTo: to, source: .litellm)
    }

    static let t0 = PriceLedgerTests.t0
    static let dayS: TimeInterval = 86_400

    func cost(_ ledger: PriceLedger, _ model: String, _ t: Date, _ b: TokenBreakdown = Self.mtok) -> Double {
        ledger.cost(model: model, at: t, breakdown: b).total
    }

    @Test func theListBeatsThisMacsOwnCatalogRecordWhereBothCover() {
        // This Mac saw a wrong $9 row on day 3 that the list never recorded.
        let ledger = PriceLedger(records: [
            Self.listed("claude-x", input: 2, from: Self.t0),
            Self.local("claude-x", input: 2, from: Self.t0 - 10 * Self.dayS, to: Self.t0 + 3 * Self.dayS),
            Self.local("claude-x", input: 9, from: Self.t0 + 3 * Self.dayS),
        ])
        #expect(abs(cost(ledger, "claude-x", Self.t0 + 5 * Self.dayS) - 2) < 1e-9)
        // Before the list existed, this Mac's own history still prices.
        #expect(abs(cost(ledger, "claude-x", Self.t0 - 5 * Self.dayS) - 2) < 1e-9)
        #expect(ledger.cost(model: "claude-x", at: Self.t0 - 5 * Self.dayS, breakdown: Self.mtok).flags.isEmpty)
    }

    @Test func aMacsOwnRecordStillPricesWhatTheListDoesNotCarry() {
        let ledger = PriceLedger(records: [
            Self.listed("claude-x", input: 2, from: Self.t0),
            Self.local("glm-9", input: 0.5, from: Self.t0),
        ])
        #expect(abs(cost(ledger, "glm-9", Self.t0 + Self.dayS) - 0.5) < 1e-9)
    }

    @Test func curatedBeatsTheListExceptForAChangeAfterTheReview() {
        let reviewed = Self.t0
        let curated = PriceRecordValue(key: CanonicalModelID(model: "claude-x"),
                                       rates: PriceLedgerTests.rates(2, read: 0.1),
                                       effectiveFrom: Self.t0 - 30 * Self.dayS, source: .curated, reviewedAt: reviewed)
        // The job seeds a curated model's first record at its curated start,
        // with whatever the catalogs say (here a stale read rate): curated wins.
        let seeded = Self.listed("claude-x", input: 2, read: 0.2, from: Self.t0 - 30 * Self.dayS,
                                 to: Self.t0 + 4 * Self.dayS)
        // A change the job saw after the review is news, and wins from its start.
        let change = Self.listed("claude-x", input: 2, read: 0.05, from: Self.t0 + 4 * Self.dayS)
        let ledger = PriceLedger(records: [curated, seeded, change])
        #expect(abs(cost(ledger, "claude-x", Self.t0 + Self.dayS, Self.mtokRead) - 0.1) < 1e-9)
        #expect(abs(cost(ledger, "claude-x", Self.t0 + 5 * Self.dayS, Self.mtokRead) - 0.05) < 1e-9)
    }

    @Test func theBundledHistoryWithAListSeededAtCuratedStartsPricesLikeTheCuratedHistoryAlone() throws {
        // Mythos Preview: the catalogs say $10/$50, the curated record
        // $25/$125. The job seeds the catalog row at the curated start, so it
        // never counts as news and the curated price stands.
        let curated = try CuratedPriceHistory.bundled()
        let preview = Self.listed("claude-mythos-preview", input: 10, from: Self.day("2026-04-07"))
        let ledger = PriceLedger(records: curated.records + [preview])
        let alone = PriceLedger(records: curated.records)
        for d in ["2026-04-08", "2026-11-12", "2026-12-25"] {
            #expect(abs(cost(ledger, "claude-mythos-preview", Self.day(d)) - cost(alone, "claude-mythos-preview", Self.day(d))) < 1e-9, "\(d)")
        }
        #expect(abs(cost(ledger, "claude-mythos-preview", Self.day("2026-11-12")) - 25) < 1e-9)
    }

    // MARK: The ledger store

    @Test func theStoreMirrorsTheListAndLeavesThisMacsRecordsAlone() throws {
        let context = ModelContext(try PriceLedgerTests.container())
        let catalog = PriceLedgerTests.catalog(["claude-x": (2, 0.2)])
        _ = try PriceLedgerStore.sync(context: context, catalog: catalog, curated: .empty, now: Self.t0)
        let localRows = try PriceLedgerTests.rows("claude-x", in: context).filter { !$0.recordId.hasPrefix("list|") }
        #expect(localRows.count == 1)

        let open = Self.listed("claude-x", input: 2, from: Self.t0 + Self.dayS)
        var withList = CuratedPriceHistory(asOf: Self.t0, records: [], catalog: [open],
                                           catalogChangedAt: Self.t0 + Self.dayS, catalogCheckedAt: Self.t0 + Self.dayS)
        let first = try PriceLedgerStore.sync(context: context, catalog: catalog, curated: withList,
                                              now: Self.t0 + Self.dayS)
        #expect(first.listChanged == 1 && first.opened.isEmpty && first.closed.isEmpty)
        #expect(first.ledger.records.filter(\.fromPriceList) == [open])

        // The job closes it and opens a new price: the row is updated, a new
        // one added, and this Mac's own record is untouched.
        var closed = open
        closed.effectiveTo = Self.t0 + 3 * Self.dayS
        let next = Self.listed("claude-x", input: 2, read: 0.1, from: Self.t0 + 3 * Self.dayS)
        withList = CuratedPriceHistory(asOf: Self.t0, records: [], catalog: [closed, next],
                                       catalogChangedAt: Self.t0 + 3 * Self.dayS, catalogCheckedAt: Self.t0 + 3 * Self.dayS)
        let second = try PriceLedgerStore.sync(context: context, catalog: catalog, curated: withList,
                                               now: Self.t0 + 3 * Self.dayS)
        #expect(second.listChanged == 2)
        #expect(second.ledger.records.filter(\.fromPriceList).sorted { $0.id < $1.id }
                == [closed, next].sorted { $0.id < $1.id })
        #expect(try PriceLedgerTests.rows("claude-x", in: context).filter { !$0.recordId.hasPrefix("list|") }
                .map(\.value) == localRows.map(\.value))
        // The list wins where it covers: day 4 reads at the list's new rate.
        #expect(abs(second.ledger.cost(model: "claude-x", at: Self.t0 + 4 * Self.dayS,
                                       breakdown: Self.mtokRead).total - 0.1) < 1e-9)
        // A copy without the section (the bundled one, say) removes the list
        // rows again; a catalog refresh never closes them meanwhile.
        let third = try PriceLedgerStore.sync(context: context, catalog: PriceLedgerTests.catalog(["claude-x": (2, 0.3)]),
                                              curated: .empty, now: Self.t0 + 5 * Self.dayS)
        #expect(third.listChanged == 2)
        #expect(third.ledger.records.filter(\.fromPriceList).isEmpty)
    }

    // MARK: When the job stops (review M1)

    /// The list checked at t0 with an open $2 record from t0 − 30 days; this
    /// Mac's own record, fetched directly once the list went stale, says $3
    /// from t0 + 12 days.
    static func staleCase() -> (list: CuratedPriceHistory, local: PriceRecordValue) {
        let list = CuratedPriceHistory(asOf: t0, records: [], catalog: [listed("claude-x", input: 2, from: t0 - 30 * dayS)],
                                       catalogChangedAt: t0 - 30 * dayS, catalogCheckedAt: t0)
        return (list, local("claude-x", input: 3, from: t0 + 12 * dayS))
    }

    @Test func aFreshListIsTakenAsItIs() {
        let (list, _) = Self.staleCase()
        #expect(!list.listIsStale(at: Self.t0 + 9 * Self.dayS))
        #expect(list.forLedger(at: Self.t0 + 9 * Self.dayS) == list)
        #expect(list.listIsStale(at: Self.t0 + 11 * Self.dayS))
        let cut = list.forLedger(at: Self.t0 + 11 * Self.dayS)
        #expect(cut.catalog.map(\.effectiveTo) == [Self.t0])
        #expect(cut.records == list.records && cut.catalogCheckedAt == list.catalogCheckedAt)
        // A record the last run opened keeps a one-second window.
        let justOpened = CuratedPriceHistory(asOf: Self.t0, records: [],
                                             catalog: [Self.listed("claude-x", input: 2, from: Self.t0)],
                                             catalogChangedAt: Self.t0, catalogCheckedAt: Self.t0)
        #expect(justOpened.forLedger(at: Self.t0 + 11 * Self.dayS).catalog[0].effectiveTo == Self.t0 + 1)
        #expect(!CuratedPriceHistory.empty.listIsStale(at: .distantFuture))
    }

    @Test func aStaleListStopsCoveringAfterItsLastCheckAndTheMacsOwnRecordsPriceWhatFollows() throws {
        let (list, local) = Self.staleCase()
        // Fresh: the list wins over this Mac's own record where both cover.
        let fresh = PriceLedger(records: list.forLedger(at: Self.t0 + 9 * Self.dayS).catalog + [local])
        #expect(abs(cost(fresh, "claude-x", Self.t0 + 13 * Self.dayS) - 2) < 1e-9)
        // Stale: after the last check, the Mac's own catalog prices it; before
        // it, the list's price stands.
        let stale = PriceLedger(records: list.forLedger(at: Self.t0 + 13 * Self.dayS).catalog + [local])
        #expect(abs(cost(stale, "claude-x", Self.t0 + 13 * Self.dayS) - 3) < 1e-9)
        #expect(abs(cost(stale, "claude-x", Self.t0 - Self.dayS) - 2) < 1e-9)
        #expect(stale.cost(model: "claude-x", at: Self.t0 - Self.dayS, breakdown: Self.mtok).flags.isEmpty)
        // Between the last check and this Mac's first direct fetch nothing
        // covers; the nearest record prices it, flagged.
        let gap = stale.cost(model: "claude-x", at: Self.t0 + 5 * Self.dayS, breakdown: Self.mtok)
        #expect(abs(gap.total - 2) < 1e-9 && gap.flags.contains(.outsideWindow))

        // Through the store: the stale cut is mirrored, and undone once the
        // list is confirmed again.
        let context = ModelContext(try PriceLedgerTests.container())
        _ = try PriceLedgerStore.sync(context: context, catalog: [:], curated: list.forLedger(at: Self.t0 + Self.dayS),
                                      now: Self.t0 + Self.dayS)
        // Stale, and this Mac's direct fetch on day 12 sees $3.
        let cut = try PriceLedgerStore.sync(context: context, catalog: PriceLedgerTests.catalog(["claude-x": (3, 0.3)]),
                                            curated: list.forLedger(at: Self.t0 + 12 * Self.dayS),
                                            now: Self.t0 + 12 * Self.dayS)
        #expect(cut.listChanged == 1)
        #expect(cut.ledger.records.filter(\.fromPriceList).map(\.effectiveTo) == [Self.t0])
        #expect(abs(cost(cut.ledger, "claude-x", Self.t0 + 13 * Self.dayS) - 3) < 1e-9)
        #expect(abs(cost(cut.ledger, "claude-x", Self.t0 - Self.dayS) - 2) < 1e-9)
        // What follows day 12 changed price, so its buckets are rebuilt.
        #expect(cut.ledger.changes(since: cut.previous).contains { $0.from >= Self.t0 })
        let confirmed = CuratedPriceHistory(asOf: Self.t0, records: [], catalog: list.catalog,
                                            catalogChangedAt: list.catalogChangedAt,
                                            catalogCheckedAt: Self.t0 + 14 * Self.dayS)
        let back = try PriceLedgerStore.sync(context: context, catalog: [:],
                                             curated: confirmed.forLedger(at: Self.t0 + 14 * Self.dayS),
                                             now: Self.t0 + 14 * Self.dayS)
        #expect(back.ledger.records.filter(\.fromPriceList).map(\.effectiveTo) == [nil])
        #expect(abs(cost(back.ledger, "claude-x", Self.t0 + 13 * Self.dayS) - 2) < 1e-9)
    }

    // MARK: Correcting a bad list price (review M2)

    @Test func aCorrectedListWithANewerCheckReplacesTheBadRecordsOnAMacThatCachedThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pricelist-fix-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("price-history.cache.json")
        let suite = "pricelist.fix.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        func serve(_ data: Data) async -> CuratedPriceHistory.RefreshResult {
            PriceListStub.serve(data)
            return await CuratedPriceHistory.refreshResult(urlSession: PriceListStub.session(), cacheURL: cache,
                                                           store: store)
        }
        let context = ModelContext(try PriceLedgerTests.container())
        func install() throws -> PriceLedger {
            try PriceLedgerStore.sync(context: context, catalog: [:], curated: CuratedPriceHistory.load(cacheURL: cache),
                                      now: Self.day("2026-11-27")).ledger
        }
        let t = Self.day("2026-11-26T12:00:00Z")
        // The bad run: Opus 4.7 listed at $50 in from 2026-11-25.
        let bad = try Self.file(rows: [Self.row("claude-opus-4-7", provider: "vertex", from: "2026-11-25T18:00:00Z", input: 50)],
                                changedAt: "2026-11-25T18:00:00Z", checkedAt: "2026-11-25T18:00:00Z")
        #expect(await serve(bad) == .updated)
        #expect(abs(cost(try install(), "vertex_ai/claude-opus-4-7", t) - 50) < 1e-9)
        // A git revert of the bot's commit brings back an older checkedAt:
        // a Mac that cached the bad copy keeps it. Hence: never revert.
        let reverted = try Self.file(rows: [], changedAt: "2026-11-20T00:00:00Z", checkedAt: "2026-11-24T00:00:00Z")
        #expect(await serve(reverted) == .current)
        #expect(abs(cost(try install(), "vertex_ai/claude-opus-4-7", t) - 50) < 1e-9)
        // The fix: the job closes the bad record when its input is mended,
        // a curated record reprices the bad window, and the run's fresh
        // checkedAt (or a --heartbeat) makes every Mac take the copy.
        var base = try Self.bundledJSON()
        var records = base["records"] as! [[String: Any]]
        records.append(["model": "claude-opus-4-7", "provider": "vertex", "effectiveFrom": "2026-11-25T18:00:00Z",
                        "effectiveTo": "2026-11-26T18:00:00Z", "reviewedAt": "2026-11-26T18:00:00Z",
                        "perMTok": ["input": 5, "output": 25, "cacheWrite5m": 6.25, "cacheWrite1h": 10, "cacheRead": 0.5],
                        "sourceURL": "https://platform.claude.com/docs/en/about-claude/pricing",
                        "note": "Corrects the price list's $50 vertex row (catalog error)."])
        base["records"] = records
        base["asOf"] = "2026-11-26T18:00:00Z"
        let fixed = try Self.file(base: base, rows: [
            Self.row("claude-opus-4-7", provider: "vertex", from: "2026-11-25T18:00:00Z", to: "2026-11-26T18:00:00Z", input: 50),
            Self.row("claude-opus-4-7", provider: "vertex", from: "2026-11-26T18:00:00Z", input: 5),
        ], changedAt: "2026-11-26T18:00:00Z", checkedAt: "2026-11-26T18:00:00Z")
        #expect(await serve(fixed) == .updated)
        let ledger = try install()
        #expect(abs(cost(ledger, "vertex_ai/claude-opus-4-7", t) - 5) < 1e-9)          // the bad window, curated
        #expect(abs(cost(ledger, "vertex_ai/claude-opus-4-7", Self.day("2026-11-27")) - 5) < 1e-9)  // after, listed
        #expect(CuratedPriceHistory.lastGoodCheck(store: store) != nil)
    }

    @Test func theSnapshotKeepsTheListAndAListlessOneIsUnchanged() throws {
        let catalog = PriceLedger.catalogTemplates(PriceLedgerTests.catalog(["claude-x": (2, 0.2)]))
        let plain = PriceCatalogSnapshot.Contents(catalog: catalog, curated: .empty)
        #expect(plain.list == nil)
        let encoded = String(decoding: try plain.encoded(), as: UTF8.self)
        #expect(!encoded.contains("\"list\""))
        let withList = PriceCatalogSnapshot.Contents(catalog: catalog, curated: CuratedPriceHistory(
            asOf: Self.t0, records: [], catalog: [Self.listed("claude-x", input: 2, from: Self.t0)]))
        #expect(withList.list?.count == 1)
        #expect(try PriceCatalogSnapshot.Contents.decode(try withList.encoded()) == withList)
    }

    // MARK: When the catalogs are still fetched directly

    static func list(checked: Date?, records: Int = 1) -> CuratedPriceHistory {
        CuratedPriceHistory(asOf: t0, records: [],
                            catalog: (0..<records).map { listed("claude-\($0)", input: 1, from: t0) },
                            catalogChangedAt: checked, catalogCheckedAt: checked)
    }

    @Test func theCatalogsAreFetchedOnlyWhenTheListFallsShort() {
        let now = Self.t0 + Self.dayS
        #expect(PriceSources.directReason(list: Self.list(checked: Self.t0), outsideList: [], now: now) == nil)
        #expect(PriceSources.directReason(list: Self.list(checked: Self.t0, records: 0), outsideList: [], now: now) == .noList)
        #expect(PriceSources.directReason(list: .empty, outsideList: [], now: now) == .noList)
        #expect(PriceSources.directReason(list: Self.list(checked: Self.t0), outsideList: [], now: Self.t0 + 11 * Self.dayS) == .stale)
        #expect(PriceSources.directReason(list: Self.list(checked: Self.t0), outsideList: [], now: Self.t0 + 9 * Self.dayS) == nil)
        #expect(PriceSources.directReason(list: Self.list(checked: Self.t0), outsideList: ["glm-9"], now: now) == .uncovered)
        // Not worked out yet on this Mac: fetch, as every Mac did before.
        #expect(PriceSources.directReason(list: Self.list(checked: Self.t0), outsideList: nil, now: now) == .uncovered)
    }

    final class Calls: @unchecked Sendable {
        var list = 0, catalogs = 0, reloads = 0
    }

    static func steps(listAge: @escaping () -> TimeInterval?, catalogAge: @escaping () -> TimeInterval?,
                      listResult: CuratedPriceHistory.RefreshResult = .updated, catalogsOK: Bool = true,
                      list: CuratedPriceHistory, outside: Set<String>?, calls: Calls,
                      onList: @escaping () -> Void = {}, onCatalogs: @escaping () -> Void = {}) -> PriceSources.Steps {
        PriceSources.Steps(
            listAge: listAge, catalogAge: catalogAge,
            fetchList: { calls.list += 1; onList(); return listResult },
            fetchCatalogs: { calls.catalogs += 1; onCatalogs(); return catalogsOK },
            list: { list }, outsideList: { outside })
    }

    @MainActor
    @Test func aPassFetchesTheListWhenDueAndTheCatalogsOnlyWhenWantedAndDue() async {
        let now = Self.t0 + Self.dayS
        let day = PriceSources.refreshInterval
        let covered = Self.list(checked: Self.t0)
        func pass(_ s: PriceSources.Steps, hourly: Bool = false, calls: Calls) async -> PricingRefreshPass.Outcome {
            await PriceSources.pass(hourly: hourly, steps: s, now: now, reload: { calls.reloads += 1 }, generation: { 0 })
        }
        // Covered: the list when due, the catalogs never.
        var calls = Calls()
        var s = Self.steps(listAge: { day + 1 }, catalogAge: { nil }, list: covered, outside: [], calls: calls)
        var o = await pass(s, calls: calls)
        #expect(calls.list == 1 && calls.catalogs == 0 && calls.reloads == 1)
        #expect(o.curatedRefreshed && o.listChecked && !o.catalogRefreshed && o.direct == nil && o.catalogSeconds == nil)
        #expect(!PriceSources.catalogsDue(s, now: now))
        // A model the list lacks: the catalogs too, on their own daily clock.
        calls = Calls()
        s = Self.steps(listAge: { 10 }, catalogAge: { day + 1 }, list: covered, outside: ["glm-9"], calls: calls)
        #expect(PriceSources.catalogsDue(s, now: now))
        o = await pass(s, calls: calls)
        #expect(calls.list == 0 && calls.catalogs == 1)
        #expect(o.direct == .uncovered && o.catalogRefreshed && o.catalogSeconds != nil && o.listChecked)
        calls = Calls()
        s = Self.steps(listAge: { 10 }, catalogAge: { 3600 }, list: covered, outside: ["glm-9"], calls: calls)
        #expect(!PriceSources.catalogsDue(s, now: now))
        o = await pass(s, hourly: true, calls: calls)
        #expect(calls.catalogs == 0 && o.catalogSeconds == nil)   // hourly or not: daily
        // A check that brings nothing new is a good one: no reload, the clock fine.
        calls = Calls()
        s = Self.steps(listAge: { day + 1 }, catalogAge: { nil }, listResult: .current, list: covered, outside: [], calls: calls)
        o = await pass(s, calls: calls)
        #expect(o.listChecked && !o.reloaded && calls.reloads == 0)
        // A failed check, and no list at all: the catalogs, failing too.
        calls = Calls()
        s = Self.steps(listAge: { day + 1 }, catalogAge: { nil }, listResult: .failed, catalogsOK: false,
                       list: .empty, outside: [], calls: calls)
        o = await pass(s, calls: calls)
        #expect(!o.listChecked && o.direct == .noList && !o.catalogRefreshed && o.catalogSeconds != nil)
        #expect(o == PricingRefreshPass.Outcome(catalogRefreshed: false, curatedRefreshed: false, reloaded: false,
                                                pricesChanged: false, listChecked: false, direct: .noList,
                                                catalogSeconds: o.catalogSeconds))
    }

    /// The app's loop over a day, `PricingRefreshLoop.tick` with `PriceSources`
    /// in it, on a clock of its own.
    @MainActor
    final class Rig {
        var now: TimeInterval = 0
        var listCheckedAt: TimeInterval?
        var catalogsAt: TimeInterval?
        var hourly = true
        var outside: Set<String> = []
        var listResult: CuratedPriceHistory.RefreshResult = .updated
        var catalogsOK = true
        var delays: [TimeInterval] = []
        let calls = Calls()

        func run(hours: Double) async {
            let list = PriceListTests.list(checked: PriceListTests.t0)
            while now < hours * 3600 {
                let steps = PriceListTests.steps(
                    listAge: { [unowned self] in listCheckedAt.map { now - $0 } },
                    catalogAge: { [unowned self] in catalogsAt.map { now - $0 } },
                    listResult: listResult, catalogsOK: catalogsOK, list: list, outside: outside, calls: calls,
                    onList: { [unowned self] in if listResult != .failed { listCheckedAt = now } },
                    onCatalogs: { [unowned self] in if catalogsOK { catalogsAt = now } })
                let clock = PriceListTests.t0 + now
                let tick = await PricingRefreshLoop.tick(.init(
                    cacheAge: { steps.listAge() },
                    hourly: { [unowned self] in hourly },
                    alsoDue: { PriceSources.catalogsDue(steps, now: clock) },
                    refresh: { hourly in
                        await PriceSources.pass(hourly: hourly, steps: steps, now: clock, reload: {}, generation: { 0 })
                    }))
                delays.append(tick.delay)
                now += tick.delay
            }
        }
    }

    @MainActor
    @Test func hourlyWhileUnpricedRefetchesOnlyTheList() async {
        // A new Claude model with no price, and a list that covers what is in
        // use: the list every hour, the catalogs never.
        let rig = Rig()
        await rig.run(hours: 24)
        #expect(rig.calls.list == 24)
        #expect(rig.calls.catalogs == 0)
        #expect(rig.delays.allSatisfy { $0 <= PricingRefreshSchedule.recheckInterval })
        // A model only the catalogs carry as well: still the list hourly, the
        // catalogs once a day.
        let both = Rig()
        both.outside = ["glm-9"]
        await both.run(hours: 48)
        #expect(both.calls.list == 48)
        #expect(both.calls.catalogs == 2)
        // A failing direct fetch is retried hourly, not every wake of a minute.
        let failing = Rig()
        failing.hourly = false
        failing.outside = ["glm-9"]
        failing.catalogsOK = false
        await failing.run(hours: 6)
        #expect((5...7).contains(failing.calls.catalogs), "\(failing.calls.catalogs)")
        #expect(failing.calls.list == 1)
    }

    @MainActor
    @Test func dailyOtherwiseAndAGoodCheckThatBroughtNothingWaitsTheDay() async {
        let rig = Rig()
        rig.hourly = false
        await rig.run(hours: 48)
        #expect(rig.calls.list == 2 && rig.calls.catalogs == 0)
        // Never more than an hour asleep, so a model that turns up unpriced
        // mid-day moves the loop to hourly within the hour.
        #expect(rig.delays.allSatisfy { $0 <= PricingRefreshSchedule.recheckInterval })
        // A dev build whose bundled history is newer than the site's: every
        // check comes back `.current`, and that is a good check, not a retry.
        let dev = Rig()
        dev.hourly = false
        dev.listResult = .current
        await dev.run(hours: 48)
        #expect(dev.calls.list == 2)
    }

    @Test func theModelsOutsideTheListArePersistedAndReportChanges() {
        let suite = "pricelist.outside.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        #expect(PriceSources.modelsOutsideList(store: store) == nil)
        #expect(PriceSources.recordModelsOutsideList([], store: store))
        #expect(PriceSources.modelsOutsideList(store: store) == [])
        #expect(!PriceSources.recordModelsOutsideList([], store: store))
        #expect(PriceSources.recordModelsOutsideList(["glm-9", "claude-new"], store: store))
        #expect(PriceSources.modelsOutsideList(store: store) == ["claude-new", "glm-9"])
    }

    // MARK: Catwalk

    @Test func catwalkIsReadInBothShapes() {
        let nested = Data(#"{"models":[{"id":"claude-a","pricing":{"input":10,"output":50,"cache_create":12.5,"cache_hit":1}}]}"#.utf8)
        let flat = Data(#"{"models":[{"id":"claude-a","cost_per_1m_in":10,"cost_per_1m_out":50,"cost_per_1m_in_cached":12.5,"cost_per_1m_out_cached":1}]}"#.utf8)
        let a = CatwalkCatalog.anthropicEntries(from: nested)["claude-a"]
        let b = CatwalkCatalog.anthropicEntries(from: flat)["claude-a"]
        for (k, v) in [("input_cost_per_token", 10e-6), ("output_cost_per_token", 50e-6),
                       ("cache_creation_input_token_cost", 12.5e-6), ("cache_read_input_token_cost", 1e-6)] {
            #expect(abs(((a?[k] as? NSNumber)?.doubleValue ?? -1) - v) < 1e-15, "\(k)")
            #expect(abs(((b?[k] as? NSNumber)?.doubleValue ?? -1) - v) < 1e-15, "\(k)")
        }
    }
}

/// Serves one body for every request: this suite's own, so it never races
/// `FeedFallbackTests` over `FeedStubProtocol`'s replies.
final class PriceListStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    static let lock = NSLock()

    static func serve(_ data: Data) { lock.lock(); body = data; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let data = Self.body; Self.lock.unlock()
        let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [PriceListStub.self]
        return URLSession(configuration: c)
    }
}

/// The price-history decoder of Pacer 0.8.0 through 0.9.4, frozen: the
/// `File` struct and `decode` of `CuratedPriceHistory.swift`, byte-identical
/// in every tag from v0.8.0 to v0.9.4 (checked when #469 added the `catalog`
/// section). Only its outputs' type names are local. Do not update it to match
/// the current decoder: its job is to be what shipped.
enum LegacyPriceHistoryDecoder {

    struct File: Decodable {
        let schema: Int
        let asOf: String
        let records: [Row]

        struct Row: Decodable {
            let model: String
            let provider: String?
            let region: String?
            let speed: String?
            let tierAbovePromptTokens: Int64?
            let effectiveFrom: String
            let effectiveTo: String?
            let perMTok: Rates
            let fastMultiplier: Double?
            let regionalMultiplier: Double?
            let reviewedAt: String?
            let sourceURL: String?
            let note: String?
        }

        struct Rates: Decodable {
            let input: Double
            let output: Double
            let cacheRead: Double
            let cacheWrite5m: Double
            let cacheWrite1h: Double
        }
    }

    enum DecodeError: Error, Equatable {
        case unsupportedSchema(Int)
        case badDate(String)
        case badField(String)
    }

    static func decode(_ data: Data) throws -> CuratedPriceHistory {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.schema == 1 else { throw DecodeError.unsupportedSchema(file.schema) }
        let asOf = try date(file.asOf)
        var out: [PriceRecordValue] = []
        for row in file.records {
            guard let provider = CanonicalModelID.Provider(rawValue: row.provider ?? "anthropic"),
                  let region = CanonicalModelID.Region(rawValue: row.region ?? "global"),
                  let speed = PriceSpeed(rawValue: row.speed ?? "standard")
            else { throw DecodeError.badField(row.model) }
            let r = row.perMTok
            for v in [r.input, r.output, r.cacheRead, r.cacheWrite5m, r.cacheWrite1h] where v < 0 || !v.isFinite {
                throw DecodeError.badField(row.model)
            }
            let from = try date(row.effectiveFrom)
            let to = try row.effectiveTo.map(date)
            if let to, to <= from { throw DecodeError.badField(row.model) }
            out.append(PriceRecordValue(
                key: CanonicalModelID(model: row.model.lowercased(), provider: provider, region: region),
                speed: speed,
                tierAbovePromptTokens: row.tierAbovePromptTokens ?? 0,
                rates: PriceRates(
                    input: r.input / 1_000_000, output: r.output / 1_000_000,
                    cacheRead: r.cacheRead / 1_000_000,
                    cacheWrite5m: r.cacheWrite5m / 1_000_000,
                    cacheWrite1h: r.cacheWrite1h / 1_000_000),
                fastMultiplier: row.fastMultiplier,
                regionalMultiplier: row.regionalMultiplier,
                effectiveFrom: from,
                effectiveTo: to,
                source: .curated,
                reviewedAt: try row.reviewedAt.map(date) ?? asOf,
                note: row.note,
                sourceURL: row.sourceURL))
        }
        let ids = out.map(\.id)
        guard Set(ids).count == ids.count else {
            throw DecodeError.badField("duplicate record (same model, provider, region, speed, tier and start)")
        }
        return CuratedPriceHistory(asOf: asOf, records: out.sorted { $0.id < $1.id })
    }

    nonisolated(unsafe) private static let dayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) private static let instantFormatter = ISO8601DateFormatter()

    static func date(_ s: String) throws -> Date {
        if let d = dayFormatter.date(from: s), s.count == 10 { return d }
        if let d = instantFormatter.date(from: s) { return d }
        throw DecodeError.badDate(s)
    }
}
