import Foundation
import Observation
import SwiftData
import Synchronization

/// The models with usage and no price, as the scan's last ledger reconcile
/// found them (`ScanCoordinator.reconcilePriceLedger`).
///
/// A model Claude Code starts using before any pricing source lists it costs
/// **$0**: a legal total, so nothing about the number says it is missing
/// (AGENTS.md, the cost silent-zero class). The reconcile already reprices
/// its history once a price appears; this is what the rest of the app reads
/// in the meantime:
/// - `PricePending`, the observable copy views read in `body`, so a cost that
///   includes one of these models carries a "price pending" mark, and loses it
///   when the price arrives;
/// - the pricing refresh loop, which checks the catalogs and the curated
///   history hourly while a newly used Claude model has no price
///   (`wantsHourlyChecks`, `PricingRefreshSchedule`);
/// - `UnpricedModelReport`, which tells Sentry once per model per Mac.
///
/// Published after the cycle's save, only when the state changes, and once
/// at the first reconcile of a coordinator: a cycle pays a comparison.
public enum UnpricedModels {

    /// What the reconcile found.
    public struct State: Equatable, Sendable {
        /// Raw ids, as the rollups key them, with usage and no price.
        public var unpriced: Set<String>
        /// Of `unpriced`, the models whose rollups carry no cost at all, so
        /// their cost reads $0: what the mark is for. In auto mode a model
        /// Claude Code costed itself (`costUSD` on its lines) has a real
        /// cost without a price of Pacer's, and gets no mark.
        public var costless: Set<String>
        /// Each unpriced model's first day of usage (`yyyy-MM-dd`, the daily
        /// rollup's key). The store keeps it, so it survives relaunches, and a
        /// history backfill of an old model is old rather than new.
        public var firstDay: [String: String]

        public init(unpriced: Set<String> = [], costless: Set<String> = [], firstDay: [String: String] = [:]) {
            self.unpriced = unpriced
            self.costless = costless
            self.firstDay = firstDay
        }

        public static let empty = State()

        /// Built from the daily rollup's rows: only the unpriced models' rows
        /// are looked at.
        public init(unpriced: Set<String>, rows: some Sequence<(model: String, date: String, cost: Double)>) {
            var firstDay: [String: String] = [:]
            var costed: Set<String> = []
            if !unpriced.isEmpty {
                for row in rows where unpriced.contains(row.model) {
                    if row.cost > 0 { costed.insert(row.model) }
                    if let day = firstDay[row.model], day <= row.date { continue }
                    firstDay[row.model] = row.date
                }
            }
            self.init(unpriced: unpriced, costless: unpriced.subtracting(costed), firstDay: firstDay)
        }
    }

    /// The app's hub.
    public static let hub = UnpricedModelsHub()

    /// What the scan coordinator calls by default.
    @discardableResult
    public static func publish(_ state: State) -> Bool { hub.publish(state) }

    /// The state as last published. Any thread.
    public static var current: State { hub.current }

    /// Whether the pricing refresh should run hourly now (`UnpricedModelsHub`).
    public static func wantsHourlyChecks(at now: Date = Date()) -> Bool { hub.wantsHourlyChecks(at: now) }

    /// The set as the store keeps it between launches
    /// (`ClaudeCodeMetaKey.unpricedModels`, a JSON array). Empty for a
    /// missing or unreadable value.
    public static func decode(_ json: String?) -> Set<String> {
        guard let data = json.map({ Data($0.utf8) }),
              let models = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return models
    }

    /// The set the last reconcile persisted, read from `context`: for a
    /// process that runs no scan of its own (the live render).
    public static func stored(in context: ModelContext) -> Set<String> {
        let key = ClaudeCodeMetaKey.unpricedModels
        var descriptor = FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return decode((try? context.fetch(descriptor))?.first?.value)
    }

    /// How long after a Claude model's first day of usage the pricing refresh
    /// runs hourly for it. A launch's price appears within days (a catalog,
    /// or a curated row); past a week, waiting hourly only re-downloads the
    /// catalogs (~1.75 MB) and rewrites their cache, so it is back to daily.
    public static let hourlyWindow: TimeInterval = 7 * 24 * 3600
}

/// Where `UnpricedModels.State` lives, and what publishing it does. One per
/// process (`UnpricedModels.hub`); tests make their own.
public final class UnpricedModelsHub: @unchecked Sendable {  // UserDefaults is thread-safe

    private struct Stored {
        var state: UnpricedModels.State = .empty
        /// The latest moment any reportable unpriced model still wants hourly
        /// checks (its first day plus `UnpricedModels.hourlyWindow`).
        var hourlyUntil: Date?
        /// Reports this process has sent (`UnpricedModelReport.perLaunchCap`).
        var reportedThisLaunch = 0
    }

    private let stored = Mutex(Stored())
    private let store: UserDefaults
    private let board: PricePending?
    private let reportsEnabled: Bool
    private let send: @Sendable (UnpricedModelReport.Report) -> Bool

    /// - `board`: the views' copy; nil is `PricePending.shared`.
    /// - `reportsEnabled`: the user's own app only. A diagnostic launch or a
    ///   test that marked a model reported would stop the real app from ever
    ///   sending it.
    /// - `send`: true when the report was taken for sending.
    public init(store: UserDefaults = PacerPreferences.store, board: PricePending? = nil,
                reportsEnabled: Bool = LaunchMode.isNormalLaunch,
                send: @escaping @Sendable (UnpricedModelReport.Report) -> Bool = UnpricedModelReport.sendToSentry) {
        self.store = store
        self.board = board
        self.reportsEnabled = reportsEnabled
        self.send = send
    }

    public var current: UnpricedModels.State { stored.withLock { $0.state } }

    /// Hourly while a reportable Claude model with no price was first used
    /// less than `UnpricedModels.hourlyWindow` ago. A model from another
    /// backend, or an alias with no version, never asks for it: nobody is
    /// going to publish a price for those, and hourly would last forever.
    public func wantsHourlyChecks(at now: Date = Date()) -> Bool {
        guard let until = stored.withLock({ $0.hourlyUntil }) else { return false }
        return now < until
    }

    /// Install `state`, hand it to the views, and report first sightings.
    /// Returns whether it changed anything.
    @discardableResult
    public func publish(_ state: UnpricedModels.State) -> Bool {
        let hourlyUntil = Self.hourlyUntil(state)
        let changed = stored.withLock { s -> Bool in
            guard s.state != state else { return false }
            s.state = state
            s.hourlyUntil = hourlyUntil
            return true
        }
        guard changed else { return false }
        // Reads `current` rather than capturing `state`, so two publishes
        // whose hops land out of order still leave the views on the latest.
        let board = self.board
        Task { @MainActor [self] in (board ?? PricePending.shared).update(current.costless) }
        reportFirstSightings(state.unpriced)
        return true
    }

    private func reportFirstSightings(_ models: Set<String>) {
        guard reportsEnabled, !models.isEmpty else { return }
        let room = stored.withLock { UnpricedModelReport.perLaunchCap - $0.reportedThisLaunch }
        guard room > 0 else { return }
        let sent = UnpricedModelReport.reportFirstSightings(models, store: store, room: room, send: send)
        if sent > 0 { stored.withLock { $0.reportedThisLaunch += sent } }
    }

    static func hourlyUntil(_ state: UnpricedModels.State) -> Date? {
        var latest: Date?
        for report in UnpricedModelReport.reports(for: state.unpriced) {
            // The model's earliest day across its spellings.
            let days = state.firstDay.filter { CanonicalModelID.parse($0.key).model == report.model }.values
            guard let day = days.min(), let start = Self.dayFormatter.date(from: day) else { continue }
            let until = start.addingTimeInterval(UnpricedModels.hourlyWindow)
            latest = max(latest ?? until, until)
        }
        return latest
    }

    /// The rollups' local-day key format (`TokenSample.formatDate`).
    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// The models whose cost is waiting on a price, for views (`UnpricedModels`):
/// `State.costless`, the ones whose cost reads $0.
///
/// Read it in `body` (a view that caches rows keys its rebuild on `models`
/// with `.onChange`): it changes when a model appears without a price and
/// again when its price arrives, and on an idle machine nothing else may
/// redraw the view in between.
@MainActor
@Observable
public final class PricePending {

    public static let shared = PricePending()

    /// Raw model ids, as the rollups key them.
    public private(set) var models: Set<String> = []

    public init() {}

    public func update(_ models: Set<String>) {
        if self.models != models { self.models = models }
    }

    /// Whether `model` has no price yet.
    public func isPending(_ model: String) -> Bool { models.contains(model) }

    /// Of `models`, the ones with no price yet, sorted: what a cost built
    /// from them is missing. Empty when it misses nothing.
    public func pending(in models: some Sequence<String>) -> [String] {
        let unpriced = self.models
        guard !unpriced.isEmpty else { return [] }
        return Set(models).intersection(unpriced).sorted()
    }
}

/// The Sentry issue for a model with no price: one per model, across every
/// Mac, and one report of it per Mac.
///
/// A new issue is what emails the owner, and an unpriced model is something
/// he acts on (a curated row in `site/public/price-history.json`, which every
/// Mac picks up within the hour while the model is new). The fingerprint
/// keys the issue on the model, so the message alone (the same for every
/// model) does not lump them into one; each Mac adds an event to it, once.
///
/// Only versioned Claude models are reported (`isVersionedClaudeID`). A model
/// from another backend Claude Code was pointed at, or a gateway alias such as
/// `claude-sonnet-acme-prod`, is not something Pacer curates a price for, and
/// its name can be a private deployment's; it stays with the counter and the
/// format drift signal (`FormatDrift.noteUnknownModel`), which already take it.
public enum UnpricedModelReport {

    /// The issue's message: fixed, so it never carries the model; the tags
    /// and the fingerprint do.
    public static let message = "Model has no price"

    /// The lookup step that ran out, the `source` tag.
    public enum Source: String, Sendable, CaseIterable {
        /// A Claude API id: no catalog (LiteLLM, models.dev, catwalk), no
        /// built-in row and no curated record for it, nor for the same model
        /// on a partner cloud's global endpoint.
        case catalog
        /// Only Bedrock, Vertex, Foundry or regional ids: none has records of
        /// its own, and the Claude API model they fall back to has none either.
        case partnerOnly = "partner_only"
    }

    /// One report: the canonical model (what a price is added under, so the
    /// Bedrock and Claude API spellings of one model are one issue) and the
    /// step that ran out.
    public struct Report: Equatable, Sendable {
        public let model: String
        public let source: Source

        public var attributes: Telemetry.Attributes {
            ["model": .string(model), "source": .string(source.rawValue)]
        }

        public var fingerprint: [String] { ["unpriced-model", model] }
    }

    /// The reports `models` (raw ids) make, before deduplication: versioned
    /// Claude models only, one per canonical model, sorted. Also what decides
    /// hourly checks and whether the mark promises a price.
    public static func reports(for models: Set<String>) -> [Report] {
        var hasAPIId: [String: Bool] = [:]
        for raw in models {
            let key = CanonicalModelID.parse(raw)
            guard key.provider != .other, isVersionedClaudeID(key.model),
                  FormatDrift.isReportable(key.model) else { continue }
            let isAPI = key.provider == .anthropic && key.region == .global
            hasAPIId[key.model] = (hasAPIId[key.model] ?? false) || isAPI
        }
        return hasAPIId.keys.sorted().map {
            Report(model: $0, source: hasAPIId[$0]! ? .catalog : .partnerOnly)
        }
    }

    /// `claude-`, then lowercase words, then a version number:
    /// `claude-sonnet-5-6`, `claude-3-5-sonnet`. Anthropic's ids always carry
    /// a version; an alias without one (`claude-sonnet-acme-prod`) is a
    /// gateway's or a company's name, and never becomes a tag.
    static func isVersionedClaudeID(_ model: String) -> Bool {
        let parts = model.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "claude" else { return false }
        for part in parts.dropFirst() {
            guard let first = part.first else { return false }
            if first.isASCII, first.isNumber { return true }
            guard part.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { return false }
        }
        return false
    }

    /// Where the models already reported on this Mac are kept.
    static let defaultsKey = "pacer.telemetry.unpricedModelsReported"
    /// Past this many, nothing more is reported: a Mac that has met a hundred
    /// unpriced Claude models is telling us nothing new.
    static let capacity = 100
    /// At most this many reports per launch; the rest go on later launches.
    /// A first launch over a long history can find several at once.
    public static let perLaunchCap = 3

    /// The app's send: true when the sink took it (`Telemetry.problem`).
    public static let sendToSentry: @Sendable (Report) -> Bool = { report in
        Telemetry.problem(message, attributes: report.attributes, fingerprint: report.fingerprint)
    }

    /// Report up to `room` of `models` not reported on this Mac before, and
    /// remember each one the sink took. One it refused (crash reports off,
    /// the error budget spent) is tried again at a later publish or launch.
    /// Returns how many were sent.
    @discardableResult
    static func reportFirstSightings(
        _ models: Set<String>, store: UserDefaults, room: Int,
        send: (Report) -> Bool
    ) -> Int {
        let candidates = reports(for: models)
        guard !candidates.isEmpty, room > 0 else { return 0 }
        var reported = store.stringArray(forKey: defaultsKey) ?? []
        var sent = 0
        for report in candidates where !reported.contains(report.model) {
            guard sent < room, reported.count < capacity else { break }
            // A refusal is the toggle or the day's budget, which the next
            // report would meet too.
            guard send(report) else { break }
            reported.append(report.model)
            sent += 1
        }
        if sent > 0 { store.set(reported, forKey: defaultsKey) }
        return sent
    }
}
