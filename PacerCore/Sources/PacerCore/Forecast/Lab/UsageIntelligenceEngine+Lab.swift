import Foundation

/// What one refit fetched from the lab helper: per window, the helper models as
/// roster members (with their predictions), their complexities, and the
/// completed cycles the fetch covered so the refit can score them.
struct LabRefit {
    var models: [String: [any BurnTrajectory.Model]] = [:]
    var complexities: [String: Int] = [:]
    var scoredCycles: [String: [BurnTrajectory.Cycle]] = [:]
    /// Per window, the lab models selection may pick: those with a prediction
    /// for the live cycle and a full-history record (the pass's marker covers
    /// them). One the helper could not answer for keeps its record on show
    /// but cannot take the window, so a helper that is down or slow leaves
    /// exactly the built-in pick. One the pass has not covered yet draws its
    /// line but waits: on a first refit its record is the two cycles that
    /// refit scored, and on the owner's store that was enough to win a window
    /// from models with hundreds of cycles behind them.
    var projecting: [String: Set<String>] = [:]

    func selectable(_ method: String, window: String) -> Bool {
        !LabHelper.isExternal(method) || projecting[window]?.contains(method) == true
    }
}

/// The full-history pass's lab bookkeeping: which models it owes, what the
/// record already holds for them, what failed.
struct LabPass {
    let models: [LabModelInfo]
    /// `surface|model|period` with at least one record row.
    var present: Set<String> = []
    /// Full record keys of lab rows, the only keys lab scoring can collide with.
    var keys: Set<String> = []
    var failed: Set<String> = []
    var added = 0

    init(models: [LabModelInfo]) { self.models = models }

    mutating func loadRecord(_ rows: [UsageIntelligenceEngine.EvalRow]) {
        for row in rows where LabHelper.isExternal(row.record.method) {
            keys.insert(row.key)
            present.insert(UsageIntelligenceEngine.labCycleKey(row.surface, row.record.method, row.record.periodKey))
        }
    }

    mutating func add(_ news: [EngineSelfEval.NewOutcome]) {
        for n in news {
            keys.insert(EngineEvalOutcome.makeKey(surface: n.surface, method: n.method, bucket: n.bucket,
                                                  periodKey: n.periodKey))
            present.insert(UsageIntelligenceEngine.labCycleKey(n.surface, n.method, n.periodKey))
        }
        added += news.count
    }
}

extension UsageIntelligenceEngine {

    /// Completed cycles a live refit scores lab models on, newest first. The
    /// full-history pass scores the rest; this only keeps the record current
    /// as cycles finish, and keeps the live request small enough for its
    /// timeout.
    static let labLiveScoredCycles = 2
    /// A model whose full-history pass failed is retried no sooner than this.
    static let labBackfillRetry: TimeInterval = 30 * 60
    /// How long a served model list is reused before it is asked for again.
    static let labCatalogMaxAge: TimeInterval = 60

    static func labMillis(_ d: Duration) -> Int {
        Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Test seam: use this fetcher instead of the configured URL (nil: none).
    func useLabHelperForTesting(_ fetcher: (any LabForecastFetching)?,
                                liveTimeout: Duration = .milliseconds(1500),
                                backfillTimeout: Duration = .seconds(20)) {
        labFetcherOverride = fetcher
        labLiveTimeout = liveTimeout
        labBackfillTimeout = backfillTimeout
    }

    /// Test seam: make the next refit ask the helper for its models again.
    func expireLabCatalogForTesting() { labCatalogFetchedAt = nil }

    /// The helper to ask, or nil when none is configured (the default).
    func labClient() -> (any LabForecastFetching)? {
        if let labFetcherOverride { return labFetcherOverride }
        guard let url = LabHelper.configuredURL() else { return nil }
        if let cached = labClientCache, cached.url == url { return cached.client }
        let client = LabHelperClient(baseURL: url)
        labClientCache = (url, client)
        return client
    }

    /// Whether a rate-limit record row counts. A lab model's rows count only
    /// while a helper is configured.
    static func countsRLRecord(_ r: EngineSelfEval.Record, labOn: Bool) -> Bool {
        labOn || !LabHelper.isExternal(r.method)
    }

    static func labCycleKey(_ surface: String, _ method: String, _ period: String) -> String {
        "\(surface)|\(method)|\(period)"
    }

    // MARK: - Served models

    /// The helper's models, refreshed when the last answer is older than
    /// `labCatalogMaxAge` or was a failure. When the helper doesn't answer, the
    /// last list it served stands, so its models stay listed as unavailable.
    func refreshLabCatalog(_ client: any LabForecastFetching, timeout: Duration) async -> [LabModelInfo] {
        if labCatalogOK, let at = labCatalogFetchedAt, Date().timeIntervalSince(at) < Self.labCatalogMaxAge {
            return labCatalog
        }
        do {
            let served = try await labWithTimeout(timeout) { try await client.models() }
            let usable = LabModelInfo.usable(served)
            if usable.map(\.id) != labCatalog.map(\.id) || !labCatalogOK {
                Log.write("Lab", "helper serves \(usable.count) model(s): "
                          + usable.map(\.id).joined(separator: ", ")
                          + (served.count == usable.count ? "" : " (\(served.count - usable.count) rejected: ids must start with lab-)"))
            }
            labCatalog = usable
            labCatalogOK = true
            LabModelCatalog.shared.register(usable)
            noteLabReachability(nil)
        } catch {
            labCatalogOK = false
            noteLabReachability(error)
        }
        labCatalogFetchedAt = Date()
        return labCatalog
    }

    /// The pass asks with its own, longer budget.
    func labCatalogForPass(_ client: any LabForecastFetching) async -> [LabModelInfo] {
        await refreshLabCatalog(client, timeout: labBackfillTimeout)
    }

    /// Log a change of reachability once, not on every refit.
    func noteLabReachability(_ error: Error?) {
        let reachable = error == nil
        guard labLoggedReachable != reachable else { return }
        labLoggedReachable = reachable
        if let error {
            Log.write("Lab", "helper not reachable (\(error)); its models have no line until it answers")
        } else {
            Log.write("Lab", "helper reachable")
        }
    }

    // MARK: - Live refit

    /// Fetch the helper's predictions for this refit: per window it serves, one
    /// request carrying the live cycle (one cut: now) and up to
    /// `labLiveScoredCycles` recently completed cycles it has no record for
    /// (every scored cut). The windows' requests run concurrently, each under
    /// `labLiveTimeout`; a window whose request fails gets its models with no
    /// predictions, so they are listed as unavailable and cannot project.
    func labRefit(_ f: EngineFeatures, client: any LabForecastFetching) async -> LabRefit {
        let models = await refreshLabCatalog(client, timeout: labLiveTimeout)
        var refit = LabRefit()
        for m in models { refit.complexities[m.id] = m.complexity }
        guard !models.isEmpty else { return refit }
        maybeReopenRecordBackfill(for: models)

        let covered = Self.coveredModels(recordBackfillMarker())
        let rows = evalRowsCache ?? fetchEvalRows()
        evalRowsCache = rows
        var present = Set<String>()
        for row in rows where LabHelper.isExternal(row.record.method) {
            present.insert(Self.labCycleKey(row.surface, row.record.method, row.record.periodKey))
        }

        struct Plan {
            let window: WindowSpec
            let models: [LabModelInfo]
            let live: BurnTrajectory.PartialCycle?
            let owed: [BurnTrajectory.Cycle]
            let request: LabForecastRequest
        }
        var plans: [Plan] = []
        for window in f.windows {
            let serving = models.filter { $0.serves(window.key) }
            guard !serving.isEmpty, let samples = f.rateLimit[window.key], !samples.isEmpty else { continue }
            let (current, history) = BurnTrajectory.segment(samples: samples, duration: window.duration, now: f.now)
            let live = current.flatMap { $0.resetsAt > f.now ? $0 : nil }
            let surface = EngineSelfEval.rlSurface(window.key)
            let owed = Array(history.filter { $0.resetsAt <= f.now }
                .sorted { $0.resetsAt > $1.resetsAt }
                .filter { c in
                    let period = EngineSelfEval.periodKeyRL(c.resetsAt)
                    return serving.contains { m in
                        let k = Self.labCycleKey(surface, m.id, period)
                        return !present.contains(k) && !labAsked.contains(k)
                    }
                }
                .prefix(Self.labLiveScoredCycles))
            var cycles: [LabForecastRequest.Cycle] = []
            if let live { cycles.append(.init(cycleStart: live.cycleStart, resetsAt: live.resetsAt, cuts: [f.now])) }
            for c in owed {
                let cuts = EngineSelfEval.rlCutInstants(c)
                if !cuts.isEmpty { cycles.append(.init(cycleStart: c.cycleStart, resetsAt: c.resetsAt, cuts: cuts)) }
            }
            let request = LabForecastRequest(
                window: window.key, duration: window.duration, account: limitAccountId, cycles: cycles,
                models: serving.map(\.id),
                deadlineMs: Self.labMillis(labLiveTimeout) * 4 / 5)
            plans.append(Plan(window: window, models: serving, live: live, owed: owed, request: request))
        }

        // One request per window, concurrently, each under the live budget.
        let timeout = labLiveTimeout
        let results: [Int: Result<LabForecastResponse, Error>] = await withTaskGroup(
            of: (Int, Result<LabForecastResponse, Error>).self
        ) { group in
            for (i, plan) in plans.enumerated() where !plan.request.cycles.isEmpty {
                let request = plan.request
                group.addTask {
                    do { return (i, .success(try await labWithTimeout(timeout) { try await client.forecast(request) })) }
                    catch { return (i, .failure(error)) }
                }
            }
            var out: [Int: Result<LabForecastResponse, Error>] = [:]
            for await (i, r) in group { out[i] = r }
            return out
        }

        var firstError: Error?
        for (i, plan) in plans.enumerated() {
            var predictions: [String: [LabKey: LabPrediction]] = [:]
            var ok = plan.request.cycles.isEmpty
            if case .success(let response)? = results[i], response.cycles.count == plan.request.cycles.count {
                ok = true
                predictions = Self.labPredictions(request: plan.request, response: response)
                // Asked and answered: not asked again this launch, scored now.
                let surface = EngineSelfEval.rlSurface(plan.window.key)
                for c in plan.owed {
                    let period = EngineSelfEval.periodKeyRL(c.resetsAt)
                    for m in plan.models { labAsked.insert(Self.labCycleKey(surface, m.id, period)) }
                }
                refit.scoredCycles[plan.window.key] = plan.owed
                if let live = plan.live {
                    let key = LabKey(resetsAt: live.resetsAt, cut: live.now)
                    refit.projecting[plan.window.key] = Set(plan.models.map(\.id).filter {
                        predictions[$0]?[key] != nil && covered.contains($0)
                    })
                }
            } else if case .failure(let error)? = results[i] {
                firstError = firstError ?? error
            } else if results[i] != nil {
                firstError = firstError ?? LabHelperError.malformed
            }
            refit.models[plan.window.key] = plan.models.map { info in
                let preds = predictions[info.id] ?? [:]
                return LabForecastModel(id: info.id, complexity: info.complexity, predictions: preds,
                                        unavailableNote: ok ? "no forecast from the lab model" : "lab helper not reachable")
            }
        }
        if !plans.isEmpty { noteLabReachability(firstError) }
        return refit
    }

    /// The response, keyed as `LabForecastModel` looks it up: the request's own
    /// cycles and cuts, matched by position, so nothing the helper echoes back
    /// can move an answer to a different cut.
    static func labPredictions(request: LabForecastRequest, response: LabForecastResponse)
        -> [String: [LabKey: LabPrediction]] {
        var out: [String: [LabKey: LabPrediction]] = [:]
        let wanted = Set(request.models)
        for (cycle, answered) in zip(request.cycles, response.cycles) {
            for (model, entries) in answered.predictions where wanted.contains(model) {
                for (cut, entry) in zip(cycle.cutDates, entries) {
                    guard let entry else { continue }
                    out[model, default: [:]][LabKey(resetsAt: cycle.resetDate, cut: cut)] = entry
                }
            }
        }
        return out
    }

    /// Outcomes for the completed cycles this refit fetched lab predictions for.
    func labOutcomes(_ lab: LabRefit, existingKeys: Set<String>) -> [EngineSelfEval.NewOutcome] {
        var out: [EngineSelfEval.NewOutcome] = []
        for (window, cycles) in lab.scoredCycles where !cycles.isEmpty {
            out += EngineSelfEval.newOutcomesRLExternal(
                window: window, cycles: cycles, models: lab.models[window] ?? [], existingKeys: existingKeys)
        }
        return out
    }

    /// Send the full-history pass round again when the helper serves a model it
    /// has not covered this launch (a predictor registered while the app runs,
    /// or a helper that was down when the pass ran). A model whose pass failed
    /// waits `labBackfillRetry` before the next try.
    func maybeReopenRecordBackfill(for models: [LabModelInfo]) {
        guard recordBackfill == .done, let covered = labIdsBackfilled else { return }
        guard !Set(models.map(\.id)).isSubset(of: covered) else { return }
        if let at = labBackfillFailedAt, Date().timeIntervalSince(at) < Self.labBackfillRetry { return }
        recordBackfill = .idle
    }

    // MARK: - Full-history pass

    /// One batch of the full-history pass for lab models: the batch's cycles
    /// that lack a record for any of `models`, in one request, scored on return.
    /// Returns the outcomes added; a failed request marks the models failed, so
    /// the marker leaves them out and a later pass retries them.
    func labBackfillBatch(client: any LabForecastFetching, window: WindowSpec, cycles: [BurnTrajectory.Cycle],
                          models: [LabModelInfo], pass: inout LabPass, now: Date) async -> Int {
        let surface = EngineSelfEval.rlSurface(window.key)
        let owed = cycles.filter { c in
            let period = EngineSelfEval.periodKeyRL(c.resetsAt)
            return models.contains { !pass.present.contains(Self.labCycleKey(surface, $0.id, period)) }
        }
        let requested = owed.compactMap { c -> (BurnTrajectory.Cycle, LabForecastRequest.Cycle)? in
            let cuts = EngineSelfEval.rlCutInstants(c)
            return cuts.isEmpty ? nil : (c, .init(cycleStart: c.cycleStart, resetsAt: c.resetsAt, cuts: cuts))
        }
        guard !requested.isEmpty else { return 0 }
        let request = LabForecastRequest(
            window: window.key, duration: window.duration, account: limitAccountId,
            cycles: requested.map(\.1), models: models.map(\.id),
            deadlineMs: Self.labMillis(labBackfillTimeout) * 9 / 10)
        let response: LabForecastResponse
        do {
            response = try await labWithTimeout(labBackfillTimeout) { try await client.forecast(request) }
            guard response.cycles.count == request.cycles.count else { throw LabHelperError.malformed }
        } catch {
            pass.failed.formUnion(models.map(\.id))
            noteLabReachability(error)
            return 0
        }
        let predictions = Self.labPredictions(request: request, response: response)
        let built: [any BurnTrajectory.Model] = models.map {
            LabForecastModel(id: $0.id, complexity: $0.complexity, predictions: predictions[$0.id] ?? [:],
                             unavailableNote: "no forecast from the lab model")
        }
        let news = EngineSelfEval.newOutcomesRLExternal(
            window: window.key, cycles: requested.map(\.0), models: built, existingKeys: pass.keys)
        persist(news, now: now)
        // Read the cache after the await: a refit may have added to it meanwhile.
        var rows = evalRowsCache ?? fetchEvalRows()
        rows.append(contentsOf: news.map(Self.evalRow))
        evalRowsCache = rows
        pass.add(news)
        return news.count
    }

    /// What the full-history pass owes, from its marker. `labIds` nil means no
    /// helper is configured, and then the rule is exactly the old one: run
    /// unless the marker is today's fingerprint. With a helper the marker is
    /// read as a set of covered models, so a lab model added later re-runs the
    /// pass for itself alone, and one the helper dropped doesn't re-run it.
    /// Nil: nothing to do.
    static func recordBackfillPlan(marker: String?, labIds: [String]?) -> (builtins: Bool, labIds: Set<String>)? {
        guard let labIds else {
            return marker == recordBackfillFingerprint ? nil : (builtins: true, labIds: [])
        }
        let covered = coveredModels(marker)
        let builtins = !recordBackfillBuiltinIds.allSatisfy(covered.contains)
        let owed = Set(labIds).subtracting(covered)
        return !builtins && owed.isEmpty ? nil : (builtins: builtins, labIds: owed)
    }

    /// The marker a pass leaves when a helper is configured: what the previous
    /// one covered (same versions), the built-ins once they have run, and the
    /// lab models it completed. With no lab model it equals the fingerprint.
    static func recordBackfillMarker(previous: String?, ranBuiltins: Bool, labDone: Set<String>) -> String {
        var ids = coveredModels(previous)
        if ranBuiltins { ids.formUnion(recordBackfillBuiltinIds) }
        ids.formUnion(labDone)
        return recordBackfillMarkerPrefix + ids.sorted().joined(separator: ",")
    }

    /// The models a marker says are covered; empty when it was written under
    /// another version (the whole record is then owed again).
    static func coveredModels(_ marker: String?) -> Set<String> {
        guard let marker, marker.hasPrefix(recordBackfillMarkerPrefix) else { return [] }
        let list = marker.dropFirst(recordBackfillMarkerPrefix.count)
        return Set(list.split(separator: ",").map(String.init))
    }
}
