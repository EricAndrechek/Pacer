import Foundation
import SwiftData

/// Every `TokenSample`, projected to plain values and fetched **once** per
/// scan cycle.
///
/// The rollup workers — daily, hourly, and project — each took the same
/// `fetch(FetchDescriptor<TokenSample>())` when they fell to their bulk path,
/// in three separate `ModelContext`s. On a cold start every bucket is new, so
/// all three fire and the same table is materialized three times: measured at
/// ~3 s each, 9 s of a 25.8 s first launch spent re-reading rows the previous
/// worker had just read.
///
/// They can't share the SwiftData objects — those are context-bound and the
/// workers are separate actors — so they share this instead. A `Sendable`
/// value type crosses actor boundaries freely, and the aggregation each worker
/// does was always pure arithmetic over exactly these fields.
public struct SampleSnapshot: Sendable {

    /// One sample, carrying only what the rollups actually read. Deliberately
    /// not every column: this is copied per row, so anything unused here is
    /// pure cost.
    public struct Row: Sendable {
        public let date: String
        public let model: String
        public let projectPath: String?
        public let sessionId: String?
        public let sampledAt: Date
        /// Local hour as STORED on the sample — never re-derived here. See
        /// `TokenSample.localHour`.
        public let localHour: Int
        public let ccVersion: String?
        public let breakdown: TokenBreakdown
        public let sourceCostUSD: Double?
        /// `TokenSample.accountId`. nil for turns recorded before the
        /// activation trail existed — see `AccountActivation`.
        public let accountId: String?
        /// `TokenSample.speed` / `.inferenceGeo` — what selects a premium price.
        public let speed: String?
        public let inferenceGeo: String?

        public init(
            date: String, model: String, projectPath: String?, sessionId: String?,
            sampledAt: Date, localHour: Int, ccVersion: String?, breakdown: TokenBreakdown,
            sourceCostUSD: Double?, accountId: String? = nil,
            speed: String? = nil, inferenceGeo: String? = nil
        ) {
            self.speed = speed
            self.inferenceGeo = inferenceGeo
            self.date = date
            self.model = model
            self.projectPath = projectPath
            self.sessionId = sessionId
            self.sampledAt = sampledAt
            self.localHour = localHour
            self.ccVersion = ccVersion
            self.breakdown = breakdown
            self.sourceCostUSD = sourceCostUSD
            self.accountId = accountId
        }
    }

    public let rows: [Row]

    public init(rows: [Row]) { self.rows = rows }

    /// Project every stored sample. The caller decides *when* — see
    /// `SampleSnapshotCache`, which makes sure that's at most once a cycle.
    ///
    /// Paged (#337), not `enumerate`d: the "floor any full walk reaches" that
    /// #327 measured at ~1.6 GB was `enumerate` itself, which peaked at 3.3 GB
    /// on a 746k-row store; a whole rebuild through `ModelWalk` peaked at
    /// 317 MB.
    public static func fetch(from container: ModelContainer) throws -> SampleSnapshot {
        var rows: [Row] = []
        // A SQL COUNT, and it saves ~20 regrowth copies of a 750k-row array.
        rows.reserveCapacity(try ModelContext(container).fetchCount(FetchDescriptor<TokenSample>()))
        var descriptor = FetchDescriptor<TokenSample>()
        // Every column `Row` reads, and nothing else — `dedupKey` and
        // `originalProjectPath` are the widest strings on the row and no
        // rollup reads them. SwiftData may ignore this (AGENTS.md); it can't
        // hurt, because nothing below touches a column left out.
        descriptor.propertiesToFetch = [
            \.date, \.model, \.projectPath, \.sessionId, \.sampledAt, \.localHour, \.ccVersion,
            \.inputTokens, \.outputTokens, \.cacheReadTokens, \.cacheCreation5mTokens,
            \.cacheCreation1hTokens, \.sourceCostUSD, \.accountId, \.speed, \.inferenceGeo,
        ]
        try ModelWalk.forEach(descriptor, in: container) { sample in
            rows.append(Row(
                date: sample.date,
                model: sample.model,
                projectPath: sample.projectPath,
                sessionId: sample.sessionId,
                sampledAt: sample.sampledAt,
                localHour: sample.localHour >= 0
                    ? sample.localHour
                    : Calendar.current.component(.hour, from: sample.sampledAt),
                ccVersion: sample.ccVersion,
                breakdown: TokenBreakdown(
                    inputTokens: sample.inputTokens,
                    outputTokens: sample.outputTokens,
                    cacheReadTokens: sample.cacheReadTokens,
                    cacheCreation5mTokens: sample.cacheCreation5mTokens,
                    cacheCreation1hTokens: sample.cacheCreation1hTokens),
                sourceCostUSD: sample.sourceCostUSD,
                accountId: sample.accountId,
                speed: sample.speed,
                inferenceGeo: sample.inferenceGeo))
        }
        return SampleSnapshot(rows: rows)
    }
}

/// Builds a `SampleSnapshot` on first request and hands the same one to every
/// later caller in the cycle.
///
/// Lazy on purpose. The overwhelmingly common cycle is incremental — a handful
/// of dirty buckets, every worker on its fast path, nobody asking for a
/// snapshot — and eagerly materializing the whole table there would turn a
/// 33 ms cycle into a multi-second one. Nothing is read until a worker
/// genuinely needs the full table, and then only once.
///
/// One instance per cycle: it caches for the life of the object, so reusing
/// one across cycles would serve stale rows.
public final class SampleSnapshotCache: @unchecked Sendable {
    private let container: ModelContainer
    private let lock = NSLock()
    private var cached: SampleSnapshot?

    public init(container: ModelContainer) {
        self.container = container
    }

    /// The cycle's snapshot, fetched on first call. Through contexts of its
    /// own: the callers are separate actors, and a `ModelContext` is not
    /// `Sendable`.
    public func snapshot() throws -> SampleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let fresh = try SampleSnapshot.fetch(from: container)
        cached = fresh
        return fresh
    }
}

/// The two things every rollup needs from a sample: its token breakdown and
/// the cost Claude Code recorded, if any.
///
/// Both a stored `TokenSample` and a snapshot `Row` satisfy it, which is what
/// lets the per-bucket fast path (real model objects, straight from the
/// context) and the bulk path (shared value snapshot) run the *same*
/// aggregation code instead of two copies that can drift on cost handling.
public protocol AggregatableSample {
    var breakdown: TokenBreakdown { get }
    var sourceCostUSD: Double? { get }
    /// Needed for the per-model cost split the project rollup keeps.
    var model: String { get }
    /// Needed for "last active" on the project and session rollups.
    var sampledAt: Date { get }
    /// Needed for the distinct-session count the project rollup keeps.
    var sessionId: String? { get }
    /// Needed by the project and session rollups.
    var projectPath: String? { get }
    /// Needed for the Claude Code version the session rollup records.
    var ccVersion: String? { get }
    /// Which account paid for this turn, or nil if it predates the trail.
    /// Lives on the shared protocol for the same reason cost does: the
    /// per-bucket and bulk paths must split by account identically or the
    /// two rollups disagree depending on which path last touched a bucket.
    var accountId: String? { get }
    /// What picks a premium price variant: fast mode, US residency (#218).
    var speed: String? { get }
    var inferenceGeo: String? { get }
}

extension SampleSnapshot.Row: AggregatableSample {}

public extension TokenSample {
    /// The five billable categories as a value, so a stored row aggregates
    /// through exactly the same path a snapshot row does.
    var breakdown: TokenBreakdown {
        TokenBreakdown(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreation5mTokens: cacheCreation5mTokens,
            cacheCreation1hTokens: cacheCreation1hTokens)
    }
}

extension TokenSample: AggregatableSample {}
