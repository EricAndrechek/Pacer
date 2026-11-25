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
///   history hourly instead of daily while this is non-empty
///   (`PricingRefreshSchedule`);
/// - `UnpricedModelReport`, which tells Sentry once per model per Mac.
///
/// Published only when the set changes, and once at the first reconcile of a
/// process: a cycle pays a set comparison and nothing else.
public enum UnpricedModels {

    private static let storage = Mutex<Set<String>>([])

    /// The set as last published. Any thread; a lock and a copy.
    public static var current: Set<String> { storage.withLock { $0 } }

    /// What the scan coordinator calls: install `models`, hand them to the
    /// views, and report any first sighting. Returns whether the set changed.
    @discardableResult
    public static func publish(_ models: Set<String>) -> Bool {
        let changed = storage.withLock { stored -> Bool in
            guard stored != models else { return false }
            stored = models
            return true
        }
        guard changed else { return false }
        // Reads `current` rather than capturing `models`, so two publishes
        // whose hops land out of order still leave the views on the latest.
        Task { @MainActor in PricePending.shared.update(UnpricedModels.current) }
        UnpricedModelReport.reportFirstSightings(models)
        return true
    }

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
}

/// The models whose cost is waiting on a price, for views (`UnpricedModels`).
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
/// Mac picks up within the hour while the model is unpriced). The fingerprint
/// keys the issue on the model, so the message alone (the same for every
/// model) does not lump them into one; each Mac adds an event to it, once.
///
/// Only Claude models are reported. A model from another backend Claude Code
/// was pointed at is not something Pacer curates a price for, and its name
/// can be a private deployment's; it stays with the counter and the format
/// drift signal (`FormatDrift.noteUnknownModel`), which already take it.
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
        case firstParty = "first_party"
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

    /// The reports `models` (raw ids) make, before deduplication: Claude
    /// models only, one per canonical model, sorted.
    public static func reports(for models: Set<String>) -> [Report] {
        var firstParty: [String: Bool] = [:]
        for raw in models {
            let key = CanonicalModelID.parse(raw)
            guard key.provider != .other, key.model.hasPrefix("claude-"),
                  FormatDrift.isReportable(key.model) else { continue }
            let isAPI = key.provider == .anthropic && key.region == .global
            firstParty[key.model] = (firstParty[key.model] ?? false) || isAPI
        }
        return firstParty.keys.sorted().map {
            Report(model: $0, source: firstParty[$0]! ? .catalog : .firstParty)
        }
    }

    /// Where the models already reported on this Mac are kept.
    static let defaultsKey = "pacer.telemetry.unpricedModelsReported"
    /// Past this many, nothing more is reported: a Mac that has met a hundred
    /// unpriced Claude models is telling us nothing new.
    static let capacity = 100

    /// Report each of `models` not reported on this Mac before, and remember
    /// it. The user's own app only: a diagnostic launch or a test that marked
    /// a model reported would stop the real app from ever sending it. Nor
    /// while crash reports are off, which would drop the event: a model is
    /// marked only when its report can go.
    public static func reportFirstSightings(
        _ models: Set<String>,
        store: UserDefaults = PacerPreferences.store,
        enabled: Bool = LaunchMode.isNormalLaunch,
        send: (Report) -> Void = { report in
            Telemetry.problem(UnpricedModelReport.message, attributes: report.attributes,
                              fingerprint: report.fingerprint)
        }
    ) {
        guard enabled, !models.isEmpty,
              PacerPreferences.telemetryCrashReportsEnabled(from: store) else { return }
        let candidates = reports(for: models)
        guard !candidates.isEmpty else { return }
        var reported = store.stringArray(forKey: defaultsKey) ?? []
        var sent = false
        for report in candidates where !reported.contains(report.model) {
            guard reported.count < capacity else { break }
            reported.append(report.model)
            send(report)
            sent = true
        }
        if sent { store.set(reported, forKey: defaultsKey) }
    }
}
