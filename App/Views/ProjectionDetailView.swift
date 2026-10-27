import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// "Compare models" modal destination for one rate-limit window. Resolves
/// its own data — actuals from SwiftData, every candidate forecaster's
/// trajectory from the engine — so it can live behind a plain
/// `PacerModalDestination.projection(window:)` route and refresh live when
/// the engine refits while it's open. Presented through the app's standard
/// dismissible-modal navigation (tap-outside / Esc / ⌘W all dismiss), like
/// every other detail surface.
struct ProjectionCompareModal: View {
    /// A fixed window key (`five_hour`/`seven_day`) OR a scoped `limits[]`
    /// identity — the modal sources actuals from `RateLimitSample` for the
    /// former, `UsageLimitSample` for the latter, and asks the engine
    /// generically by window key either way.
    let windowKey: String

    @Environment(\.usageEngines) private var engines
    @Environment(\.modelContext) private var modelContext
    /// The window's last 8 days, loaded off the main actor on every rate-limit
    /// write. These were `@Query`s, but the poller saves through its own
    /// `ModelContext` and nothing documents that such a save reaches a
    /// main-context `@Query`. With the modal open on an idle machine, a new
    /// poll did not move the actual line or the "N% used" subtitle until some
    /// unrelated main-context save (#163; AGENTS.md, "SwiftData facts").
    @State private var points: [LimitSamplePoint] = []
    @State private var scopedPoints: [ScopedSamplePoint] = []
    @State private var scopedLatest: ScopedWindowRow?
    @State private var actualsLoaded = false
    @State private var trajectories: [BurnTrajectory.ScoredTrajectory] = []
    @State private var accuracy: EngineSelfEval.Accuracy?
    /// The arena models for this window that `trajectories` doesn't list
    /// (`arenaModelList`), best record first: the "More models" rows.
    @State private var otherModels: [ArenaModelListing] = []
    @State private var loaded = false
    /// How close the live meter has been today (#318), recomputed with the
    /// actuals; nil without a live fit or enough readings.
    /// The readings against the live estimate just before each, and today's
    /// agreement (#318), recomputed with the actuals off the main actor;
    /// nil without a live fit or enough readings. Nothing is stored.
    @State private var liveReview: LiveMeterDrift.Review?

    /// The account whose actuals to plot, inherited from the card that opened
    /// the modal — a drill-down that changed scope on the way in would be
    /// showing a different question's answer.
    let limitAccountId: String?

    init(windowKey: String, limitAccountId: String? = nil) {
        self.windowKey = windowKey
        self.limitAccountId = limitAccountId
    }

    private var isFixed: Bool {
        windowKey == RateLimitWindowName.fiveHour || windowKey == RateLimitWindowName.sevenDay
    }

    private var duration: TimeInterval {
        if windowKey == RateLimitWindowName.fiveHour { return 5 * 3600 }
        if windowKey == RateLimitWindowName.sevenDay { return 7 * 86400 }
        return WindowSpec.scopedDuration(group: scopedLatest?.group ?? "weekly")
    }
    private var windowTitle: String {
        if windowKey == RateLimitWindowName.fiveHour { return "5-hour" }
        if windowKey == RateLimitWindowName.sevenDay { return "7-day" }
        return scopedLatest?.label ?? "Model"
    }

    /// The latest reading this modal loaded, through the shared live meter
    /// (#318). Read from `body`, so a new live value redraws the modal.
    private var readout: LiveMeterReadout? {
        let reading: MeterReading?
        if isFixed {
            reading = points.last.map { MeterReading(at: $0.sampledAt, percent: $0.usedPercentage, resetsAt: $0.resetsAt) }
        } else {
            reading = scopedLatest.map { MeterReading(at: $0.sampledAt, percent: $0.percent, resetsAt: $0.resetsAt) }
        }
        return reading.map { LiveMeterBoard.shared.readout(account: limitAccountId, window: windowKey, reading: $0) }
    }

    /// Current-cycle actuals + a synthesized "now" tail, from whichever source
    /// backs this window (fixed 5h/7d → `RateLimitSample`; scoped → the scoped
    /// identity's `UsageLimitSample` history), ending at the live value when
    /// there is one.
    private var chartData: PaceChartView.Data? {
        let now = Date()
        let data: PaceChartView.Data?
        if isFixed {
            data = .cycle(fixed: points, duration: duration, now: now)
        } else {
            guard let row = scopedLatest else { return nil }
            data = .cycle(scoped: row, history: scopedPoints, duration: duration, now: now)
        }
        guard let data,
              !DisplayCycle.resolve(resetsAt: data.resetsAt, duration: duration).isAwaiting
        else { return nil }
        return readout.map { data.withLive($0, now: data.points.last?.time ?? now) } ?? data
    }

    /// "62% used · resets Mon 6 AM" — the cycle context the chart is read in;
    /// "62.4% used" when the number is the live meter's estimate (#318).
    private var subtitle: String? {
        guard let data = chartData else { return nil }
        let used = "\(readout?.text ?? PacerMeterFormat.percent(data.usedPct, isEstimate: false)) used"
        let resets = "resets \(data.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour()))"
        return "\(used) · \(resets)"
    }

    var body: some View {
        // Filled in after the modal is on screen and read inside
        // `PacerModalContent`'s stored closure, so read here too (#140;
        // AGENTS.md, "SwiftUI state and data flow").
        let _ = (trajectories, accuracy, otherModels, loaded, actualsLoaded, liveReview)
        // Read here, by value, so a poll written by any context reloads the
        // actuals (`RateLimitWriteSignal`).
        let writes = RateLimitWriteSignal.shared.generation
        // The live number, read here too: when it moves, the fan is re-asked
        // from it (#318).
        let livePercent = readout?.live?.percent
        PacerModalContent(
            title: "\(windowTitle) projection",
            subtitle: subtitle,
            minHeight: 480,
            idealHeight: 580
        ) {
            if let data = chartData, !trajectories.isEmpty {
                // Re-anchor every model's projection onto the live actual tail
                // so the dashed lines (and the "now" rule) branch from exactly
                // where the solid line ends — the engine's snapshot origin is
                // otherwise stale, leaving the whole fan starting below and to
                // the left of the current dot.
                let overlays = data.tip.map { tail in
                    trajectories.map { $0.reanchored(toTime: tail.time, value: tail.value) }
                } ?? trajectories
                ProjectionDetailView(
                    cycleStart: data.cycleStart,
                    resetsAt: data.resetsAt,
                    durationSeconds: duration,
                    actual: data.points,
                    live: data.live,
                    trajectories: overlays,
                    accuracy: accuracy,
                    otherModels: otherModels,
                    liveReadout: readout?.isEstimate == true ? readout : nil,
                    liveReview: liveReview
                )
            } else if loaded && actualsLoaded {
                Text("Not enough data to compare models yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task { await refresh() }
        .task(id: writes) { await loadActuals() }
        .onChange(of: livePercent) { _, _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refresh() }
        }
    }

    /// The window's actuals for the last 8 days, fetched on a background
    /// context and handed back as values. The cutoff is taken per load so it
    /// stays 8 days wide however long the modal is open.
    private func loadActuals() async {
        let container = modelContext.container
        let key = windowKey, account = limitAccountId, fixed = isFixed
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        let loaded = await Task.detached(priority: .userInitiated) {
            () -> (points: [LimitSamplePoint], scoped: [ScopedSamplePoint], latest: ScopedWindowRow?) in
            let context = ModelContext(container)
            if fixed {
                let descriptor = FetchDescriptor<RateLimitSample>(
                    predicate: account == nil
                        ? #Predicate<RateLimitSample> { $0.window == key && $0.sampledAt >= cutoff }
                        : #Predicate<RateLimitSample> {
                            $0.window == key && $0.sampledAt >= cutoff && $0.accountId == account
                        },
                    sortBy: [SortDescriptor(\.sampledAt)])
                return ((try? context.fetch(descriptor))?.map(\.limitPoint) ?? [], [], nil)
            }
            // Two accounts can report a scoped window under the *same*
            // identity, so the account filter is not merely tidier — unscoped
            // it would interleave two series into one line.
            let descriptor = FetchDescriptor<UsageLimitSample>(
                predicate: account == nil
                    ? #Predicate<UsageLimitSample> { $0.identity == key && $0.sampledAt >= cutoff }
                    : #Predicate<UsageLimitSample> {
                        $0.identity == key && $0.sampledAt >= cutoff && $0.accountId == account
                    },
                sortBy: [SortDescriptor(\.sampledAt)])
            let rows = (try? context.fetch(descriptor)) ?? []
            return ([], rows.map(\.scopedPoint), rows.last?.scopedWindowRow)
        }.value
        points = loaded.points
        scopedPoints = loaded.scoped
        scopedLatest = loaded.latest
        actualsLoaded = true
        // Recomputed from the readings and turns at each new reading;
        // nothing about it is stored. The chart covers this window's cycle,
        // at most its last day; the agreement line, today.
        guard let account else { return }
        let resets = fixed ? loaded.points.last?.resetsAt : loaded.latest?.resetsAt
        let window = duration
        liveReview = await Task.detached(priority: .utility) {
            let now = Date()
            let cycleStart = resets.map { $0.addingTimeInterval(-window) } ?? now.addingTimeInterval(-window)
            return LiveMeterDrift.review(context: ModelContext(container), account: account, window: key,
                                         chartFrom: max(cycleStart, now.addingTimeInterval(-86_400)),
                                         agreementSince: Calendar.current.startOfDay(for: now), now: now)
        }.value
    }

    private func refresh() async {
        // This scope's engine, so the fan being compared was fitted to the
        // actuals underneath it.
        guard let engine = engines?.engine(forAccount: limitAccountId) else {
            loaded = true
            return
        }
        let key = windowKey
        let live = readout?.live
        typealias Answer = (trajectories: [BurnTrajectory.ScoredTrajectory], accuracy: EngineSelfEval.Accuracy?,
                            others: [ArenaModelListing])
        let computed = await askEngine { () -> Answer in
            let trajectories = await engine.rateLimitTrajectories(windowKey: key, live: live)
            // Every arena model for the window, less the ones listed above
            // with the lines: filtered here, once per answer, not per redraw.
            let listed = Set(trajectories.map(\.modelId))
            let others = await engine.arenaModelList(windowKey: key, live: live).filter { !listed.contains($0.id) }
            return (trajectories, await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface(key)), others)
        }
        trajectories = computed.trajectories
        accuracy = computed.accuracy
        otherModels = computed.others
        loaded = true
    }
}

/// The compare-models content: the actual usage curve with **every**
/// candidate forecaster's projection overlaid and labelled, plus each
/// model's backtest accuracy. Chrome (title, subtitle, close) comes from
/// the enclosing `PacerModalContent`.
struct ProjectionDetailView: View {
    let cycleStart: Date
    let resetsAt: Date
    let durationSeconds: TimeInterval
    let actual: [PaceChartView.Data.Point]
    /// The live meter's value at now (#318): a dotted stretch from the last
    /// reading, where the projections start. Nil: the line ends at the
    /// reading.
    var live: PaceChartView.Data.Point? = nil
    let trajectories: [BurnTrajectory.ScoredTrajectory]
    /// Per-method scored record for this window (completed cycles + median
    /// miss) — powers the selected model's earned-record footer. Nil until
    /// the engine has scored a cycle.
    let accuracy: EngineSelfEval.Accuracy?
    /// The window's arena models with no row above (no line slot this
    /// refit), best record first: listed under "More models" with their
    /// record or why there is none yet.
    var otherModels: [ArenaModelListing] = []
    /// The live meter's estimate and the reading under it (#318), for the
    /// line under the chart; nil when the number is the reading.
    var liveReadout: LiveMeterReadout? = nil
    /// The readings against the live estimate just before each, and how close
    /// it has been today; nil without a live fit.
    var liveReview: LiveMeterDrift.Review? = nil

    /// Whether "More models" is open. Collapsed by default, about thirty rows
    /// under the dozen drawn, and kept once opened, here and on every window.
    @AppStorage("pacer.projection.moreModelsExpanded", store: PacerSettings.store)
    private var moreModelsExpanded = false
    /// Open in `make render-live`, which cannot click it: a render of the
    /// sheet is for looking at what it lists.
    private var showsMoreModels: Bool { moreModelsExpanded || LiveRenderMode.isActive }

    /// Stable per-model colors for the lines and the legend swatches.
    private static let palette: [String: Color] = [
        "linear-recent": .blue,
        "recency-weighted": .green,
        "damped-acceleration": .purple,
        "saturating": .orange,
        "kalman-trend": .pink,
        "diurnal-rate": .teal,
        "recent-rate": .indigo,
    ]
    private func color(_ id: String) -> Color { Self.palette[id] ?? Self.arenaColor(id) }

    /// A ported arena model's colour: picked from its id with a hash that is
    /// the same on every launch (`hashValue` is seeded per process), so a
    /// model keeps its colour, and from hues the engine's models don't use.
    private static let arenaPalette: [Color] = [.cyan, .mint, .brown, .red, .yellow,
                                                Color(red: 0.55, green: 0.45, blue: 0.85)]
    private static func arenaColor(_ id: String) -> Color {
        let h = id.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fff_ffff }
        return arenaPalette[h % arenaPalette.count]
    }

    /// The models with a line this cycle. The chart, its domain and spread are
    /// built from these; the table lists every model (#307).
    private var projecting: [BurnTrajectory.ScoredTrajectory] { trajectories.filter(\.canProject) }

    // MARK: - Zoom domain

    /// The instant all trajectories branch from (their shared first point).
    private var trajectoryNow: Date? {
        projecting.first?.trajectory.points.first?.at
    }

    /// Chart x-axis right edge: the latest `at` across all trajectories' last
    /// points, padded by 8 % of (that latest − trajectoryNow), clamped to ≤
    /// resetsAt. Falls back to resetsAt when trajectories are empty.
    private var xEnd: Date {
        guard let now = trajectoryNow,
              let rawEnd = projecting.compactMap({ $0.trajectory.points.last?.at }).max()
        else { return resetsAt }
        let span = rawEnd.timeIntervalSince(now)
        // Degenerate at the cap: every trajectory has collapsed to its origin
        // (re-anchored onto a tail already at 100%), so there's no forward
        // span. Fall back to the full window so the x-domain stays valid.
        guard span > 0 else { return resetsAt }
        let padded = rawEnd.addingTimeInterval(span * 0.08)
        return min(padded, resetsAt)
    }

    /// Chart x-axis left edge: "now" minus 25% of the visible window width
    /// (now → xEnd), clamped so we never show before cycleStart.
    private var zoomStart: Date {
        guard let now = trajectoryNow else { return cycleStart }
        let windowSpan = xEnd.timeIntervalSince(now)
        let lookback = windowSpan * 0.25
        return max(cycleStart, now.addingTimeInterval(-lookback))
    }

    // MARK: - Filtered actuals (for the zoomed x-domain)

    /// Actual points at or after zoomStart, with one leading bridging point
    /// (the last point before zoomStart) so the line enters from the left edge.
    private var filteredActuals: [PaceChartView.Data.Point] {
        let splitIdx = actual.firstIndex(where: { $0.time >= zoomStart }) ?? actual.endIndex
        var result: [PaceChartView.Data.Point] = []
        if splitIdx > 0 {
            result.append(actual[splitIdx - 1])   // bridging point
        }
        result.append(contentsOf: actual[splitIdx...])
        return result
    }

    // MARK: - Y domain

    /// Highest value across filtered actuals + all trajectories.
    private var dataMax: Double {
        let actMax = filteredActuals.map(\.value).max() ?? 0
        let trajMax = projecting.flatMap { $0.trajectory.points.map(\.usedPercentage) }.max() ?? 0
        return max(actMax, trajMax)
    }

    /// Zoomed y-domain based on filtered actuals + all trajectories. The
    /// `dataMax + 12` cap keeps the 100% line out of frame when nothing
    /// comes near it, instead of always forcing a third of the plot empty.
    /// Hard ceiling at 100 — utilization can't exceed it, and axis room
    /// above 100% reads as if it could (Eric, 2026-06-12).
    private var yMax: Double {
        min(100, max(25, min(dataMax * 1.3, dataMax + 12)))
    }

    /// Padding below the lowest visible value scales with the data's
    /// vertical span — at 90% used the old fixed −10 floor left over half
    /// the plot empty under the lines.
    private var yMin: Double {
        let actMin = filteredActuals.map(\.value).min() ?? 0
        let trajMin = projecting.flatMap { $0.trajectory.points.map(\.usedPercentage) }.min() ?? 0
        let minVisible = min(actMin, trajMin)
        guard minVisible > 30 else { return 0 }
        let pad = max(2, (dataMax - minVisible) * 0.1)
        return max(0, floor((minVisible - pad) / 5) * 5)
    }

    // MARK: - Envelope

    /// One shared time step for the min/max fan envelope.
    struct EnvelopeStep {
        let t: Date
        let lo: Double
        let hi: Double
    }

    /// ~24 linearly-spaced steps from trajectoryNow → xEnd. For each step,
    /// interpolate every trajectory's value (clamping at 100 once capped).
    /// Values past a trajectory's last point extend at that last value, so
    /// stepping to xEnd (which may be before resetsAt) is correct.
    private var envelopeSteps: [EnvelopeStep] {
        guard let now = trajectoryNow, !projecting.isEmpty else { return [] }
        let span = xEnd.timeIntervalSince(now)
        guard span > 0 else { return [] }
        let steps = 24
        return (0...steps).compactMap { i in
            let frac = Double(i) / Double(steps)
            let t = now.addingTimeInterval(span * frac)
            var vals: [Double] = []
            for st in projecting {
                vals.append(interpolatedValue(st.trajectory.points, at: t))
            }
            guard !vals.isEmpty else { return nil }
            return EnvelopeStep(t: t, lo: vals.min()!, hi: vals.max()!)
        }
    }

    /// Linear interpolation of a trajectory's usedPercentage at time t.
    /// Past the last point: treat as its last value (typically 100 at cap).
    private func interpolatedValue(_ points: [BurnTrajectory.Sample], at t: Date) -> Double {
        guard !points.isEmpty else { return 100 }
        if t <= points.first!.at { return points.first!.usedPercentage }
        if t >= points.last!.at  { return points.last!.usedPercentage }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if t >= a.at && t <= b.at {
                let span = b.at.timeIntervalSince(a.at)
                guard span > 0 else { return a.usedPercentage }
                let frac = t.timeIntervalSince(a.at) / span
                return a.usedPercentage + frac * (b.usedPercentage - a.usedPercentage)
            }
        }
        return points.last!.usedPercentage
    }

    // MARK: - Ranked list (visual order = descending value at right edge)

    /// Models ordered by their value at the chart's right edge, descending
    /// (highest line on chart = first row). Capped trajectories whose last
    /// point is 100 are sorted earliest-cap-first among ties. The selected
    /// model keeps its highlight but does not jump the order.
    private var ranked: [BurnTrajectory.ScoredTrajectory] {
        // Models without a line go last, keeping the engine's order.
        projecting.sorted { a, b in
            let aVal = a.trajectory.points.last?.usedPercentage ?? 0
            let bVal = b.trajectory.points.last?.usedPercentage ?? 0
            if aVal != bVal { return aVal > bVal }
            // tie-break: earlier cap crossing first
            switch (a.trajectory.crossesFullAt, b.trajectory.crossesFullAt) {
            case (let ac?, let bc?): return ac < bc
            case (.some, .none):     return true
            case (.none, .some):     return false
            default:                 return false
            }
        } + trajectories.filter { !$0.canProject }
    }

    // MARK: - Body

    /// Anthropic's readings against the live estimate just before each, over
    /// this window's cycle (at most its last day), ending at the estimate
    /// now (#318). Small, under the forecast chart; absent without a fit.
    @ViewBuilder
    private var liveComparison: some View {
        if let review = liveReview, review.readings.count >= 2, let first = review.readings.first {
            let readings = review.readings.map { PaceChartView.Data.Point(time: $0.at, value: $0.percent) }
            let estimates = comparisonEstimates(review)
            VStack(alignment: .leading, spacing: 4) {
                Text("Readings and the live estimate")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                LiveMeterComparisonChart(readings: readings, estimates: estimates, start: first.at,
                                         end: estimates.last.map { max($0.time, readings.last?.time ?? $0.time) }
                                            ?? readings.last?.time ?? first.at)
                    .frame(height: 90)
                Text("Solid: Anthropic's readings. Dotted: the estimate just before each.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The estimate just before each reading, then the estimate now when the
    /// number on screen is one, so the dotted line ends where the hero is.
    private func comparisonEstimates(_ review: LiveMeterDrift.Review) -> [PaceChartView.Data.Point] {
        var out = review.estimates.map { PaceChartView.Data.Point(time: $0.at, value: $0.shown) }
        if let r = liveReadout, let asOf = r.live?.asOf, asOf > (out.last?.time ?? .distantPast) {
            out.append(.init(time: asOf, value: r.percent))
        }
        return out
    }

    /// "Live meter: 45.2%, read 42% 3m ago · within 1 point of the next
    /// reading 90% of the time today". Either half alone when only it
    /// applies. The reading's age is on the shared minute schedule
    /// (`PacerReadAge`).
    @ViewBuilder
    private var liveLine: some View {
        let agreement = liveReview?.agreement.map {
            "within 1 point of the next reading \(Int(($0.share * 100).rounded()))% of the time today"
        }
        if let r = liveReadout {
            let whole = PacerMeterFormat.percent(r.reading.percent, isEstimate: false)
            let reset = r.live?.restarted == true ? ", reset since" : ""
            let tail = agreement.map { " · \($0)" } ?? ""
            PacerAgeLabel(r.reading.at) { age in
                Text("Live meter: \(r.text), read \(whole) \(age)\(reset)\(tail)")
            }
        } else if let agreement {
            Text("Live meter: \(agreement)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            chart.frame(height: 240)
            liveComparison
            liveLine
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            accuracyTable
            Text(legendText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// One-line legend; when the dashboard's pick isn't the single most
    /// accurate model (the selector treats models within ±1.5 points as tied
    /// and prefers the simpler one), say so — otherwise the list invites
    /// "why isn't the best one picked?".
    private var legendText: String {
        var s = "Solid — actual · dashed — projections from now · shaded — the models' spread · the highlighted model drives the dashboard."
        let best = projecting.filter { $0.typicalAbsError.isFinite }.min { $0.typicalAbsError < $1.typicalAbsError }
        if let best, let selected = trajectories.first(where: { $0.isSelected }),
           selected.modelId != best.modelId {
            s += " Models within ±1.5 points are treated as tied — the simplest of the tied models is used."
        }
        return s
    }

    private var chart: some View {
        Chart {
            envelopeMarks
            paceMarks
            actualMarks
            trajectoryMarks
            nowRuleMark
        }
        .chartXScale(domain: zoomStart...xEnd)
        .chartYScale(domain: yMin...yMax)
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine(); AxisValueLabel() } }
        .chartPlotStyle { $0.clipped() }
    }

    // MARK: - Chart marks

    /// Filled envelope band spanning the per-step min/max across all trajectories.
    /// Drawn first so it sits behind all lines.
    @ChartContentBuilder private var envelopeMarks: some ChartContent {
        ForEach(Array(envelopeSteps.enumerated()), id: \.offset) { _, step in
            AreaMark(
                x: .value("t", step.t),
                yStart: .value("lo", step.lo),
                yEnd: .value("hi", step.hi),
                series: .value("s", "envelope")
            )
            .foregroundStyle(Color.secondary.opacity(0.08))
            .interpolationMethod(.monotone)
        }
    }

    /// The 0→100 ideal-burn reference, drawn across the visible window.
    ///
    /// Both marks carry the style — a modifier after the second LineMark
    /// styles only that mark, and the first then renders in the chart's
    /// default (blue, solid) series color. The endpoints are the global
    /// 0→100 line evaluated at the visible window edges (zoomStart and
    /// xEnd), which may be well before reset when trajectories cap early.
    /// `.chartPlotStyle { $0.clipped() }` is the backstop: even if the
    /// left endpoint's y falls below yMin, the line cannot escape the plot
    /// frame.
    @ChartContentBuilder private var paceMarks: some ChartContent {
        let leftVal = PaceMath.paceFraction(
            now: zoomStart, resetsAt: resetsAt, windowDuration: durationSeconds) * 100
        let rightVal = PaceMath.paceFraction(
            now: xEnd, resetsAt: resetsAt, windowDuration: durationSeconds) * 100
        // Evaluate the SAME global burn line at both visible window edges so
        // the slope is correct and the line never extends past xEnd.
        ForEach([(zoomStart, leftVal), (xEnd, rightVal)], id: \.0) { t, v in
            LineMark(x: .value("t", t), y: .value("pct", v), series: .value("s", "pace"))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        if yMax >= 100 {
            RuleMark(y: .value("full", 100))
                .foregroundStyle(.secondary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
    }

    /// Actuals colored by pace band per run — the same green/yellow/red
    /// grammar the dashboard chart uses, instead of one undifferentiated line.
    /// Operates on filteredActuals to match the zoomed x-domain.
    @ChartContentBuilder private var actualMarks: some ChartContent {
        ForEach(filteredRuns) { run in
            ForEach(run.points) { p in
                LineMark(x: .value("t", p.time), y: .value("pct", p.value),
                         series: .value("s", "actual-\(run.id)"))
                    .foregroundStyle(run.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        // The live meter's estimate past the last reading (#318), dotted
        // like the pace card's.
        if let live, let last = filteredActuals.last, live.time > last.time {
            ForEach([last, live]) { p in
                LineMark(x: .value("t", p.time), y: .value("pct", p.value), series: .value("s", "live"))
                    .foregroundStyle(bandColor(at: live))
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [0.5, 4]))
            }
        }
        if let tail = live ?? filteredActuals.last {
            PointMark(x: .value("t", tail.time), y: .value("pct", tail.value))
                .foregroundStyle(bandColor(at: tail))
                .symbolSize(60)
        }
    }

    /// Vertical rule at "now" (where trajectories branch off).
    @ChartContentBuilder private var nowRuleMark: some ChartContent {
        if let now = trajectoryNow {
            RuleMark(x: .value("now", now))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    // MARK: - Actual runs (zoomed)

    /// Contiguous same-band runs of the actual line (mirrors PaceChartView),
    /// operating on the zoomed filtered actuals.
    private struct BandRun: Identifiable {
        let id: Int
        let points: [PaceChartView.Data.Point]
        let color: Color
    }

    private var filteredRuns: [BandRun] {
        buildRuns(from: filteredActuals)
    }

    private func buildRuns(from pts: [PaceChartView.Data.Point]) -> [BandRun] {
        var runs: [BandRun] = []
        var i = 0
        while i < pts.count {
            let c = bandColor(at: pts[i])
            var j = i + 1
            while j < pts.count, bandColor(at: pts[j]) == c { j += 1 }
            // Overlap one point so adjacent runs connect without gaps.
            let upper = min(j + 1, pts.count)
            runs.append(BandRun(id: runs.count, points: Array(pts[i..<upper]), color: c))
            i = j
        }
        return runs
    }

    private func bandColor(at p: PaceChartView.Data.Point) -> Color {
        let pace = PaceMath.paceFraction(
            now: p.time, resetsAt: resetsAt, windowDuration: durationSeconds) * 100
        return PaceBand(usedPct: p.value, paceEndPct: pace).color
    }

    // MARK: - Trajectory marks

    /// Pre-resolved styling so the chart builder stays trivial (the inline
    /// ternaries overwhelmed the type-checker).
    private struct StyledLine: Identifiable {
        let id: String
        let points: [BurnTrajectory.Sample]
        let color: Color
        let width: CGFloat
        let dash: [CGFloat]
    }
    private var styledLines: [StyledLine] {
        projecting.map { st in
            StyledLine(
                id: st.modelId,
                points: st.trajectory.points,
                color: color(st.modelId).opacity(st.isSelected ? 1.0 : 0.75),
                width: st.isSelected ? 2.6 : 1.8,
                dash: st.isSelected ? [6, 3] : [4, 4])
        }
    }

    @ChartContentBuilder private var trajectoryMarks: some ChartContent {
        ForEach(styledLines) { line in
            ForEach(line.points, id: \.at) { p in
                LineMark(x: .value("t", p.at), y: .value("pct", p.usedPercentage),
                         series: .value("s", "m-\(line.id)"))
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: line.width, dash: line.dash))
                    .interpolationMethod(.monotone)
            }
        }
    }

    // MARK: - Accuracy table

    /// The selected model's earned record — how many completed cycles back
    /// it. The miss itself already sits in the row's "within ±N%" column
    /// (no number twice); the footer adds the depth of evidence behind the
    /// pick. Only claim a record once it's meaningfully sized (≥ 5 cycles).
    private var selectedRecordText: String? {
        guard let selected = trajectories.first(where: { $0.isSelected }),
              let stat = accuracy?.methods.first(where: { $0.method == selected.modelId }),
              stat.periods >= 5
        else { return nil }
        return "Selected: \(BurnTrajectory.displayName(selected.modelId)) — "
            + "earned on \(stat.periods) of your completed cycles."
    }

    private var accuracyTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column headers make the right-hand number self-explanatory —
            // it's how far each model's final-value calls have missed on
            // this user's completed cycles.
            HStack {
                Text("MODEL")
                Spacer()
                Text("TYPICAL ACCURACY, PAST CYCLES")
                    .help("Typical |shown final − actual final| at this half of the window (first or second) across your completed cycles (median; mean on weekly windows), in percentage points — lower is better")
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            ForEach(Array(ranked.enumerated()), id: \.element.id) { idx, st in
                ModelListRow(
                    modelId: st.modelId, windowDuration: durationSeconds, stat: stat(st.modelId),
                    swatch: color(st.modelId).opacity(st.canProject ? 1 : 0.35), accent: color(st.modelId),
                    isSelected: st.isSelected, note: st.unavailableReason.map { "can't project yet · \($0)" }
                ) {
                    if let crossAt = st.trajectory.crossesFullAt {
                        // Counts down on the shared minute schedule while the
                        // sheet stays open.
                        TimelineView(PacerReadAge.Schedule()) { context in
                            Text("limit \(pacerRelative(crossAt, style: .short, now: context.date))")
                                .help(pacerRelativeExact(crossAt))
                                .font(.system(size: 11)).foregroundStyle(.red.opacity(0.85))
                        }
                    }
                    Self.accuracyText(st.typicalAbsError.isFinite ? st.typicalAbsError : nil)
                }
                if idx != ranked.indices.last {
                    Divider().opacity(0.25).padding(.leading, 34)
                }
            }

            if let record = selectedRecordText {
                Text(record)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            moreModels
        }
    }

    private func stat(_ id: String) -> EngineSelfEval.Accuracy.MethodStat? {
        accuracy?.methods.first { $0.method == id }
    }

    /// "within ±3%", the column's number; "—" without one.
    private static func accuracyText(_ error: Double?) -> some View {
        Text(error.map { String(format: "within ±%.0f%%", $0) } ?? "—")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Every other model this window can run, behind one disclosure: no line,
    /// so no swatch; its record when it has one, else where its record is.
    @ViewBuilder
    private var moreModels: some View {
        if !otherModels.isEmpty {
            Button { moreModelsExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: showsMoreModels ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 14)
                    Text("More models (\(otherModels.count))")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)

            if showsMoreModels {
                ForEach(Array(otherModels.enumerated()), id: \.element.id) { idx, m in
                    ModelListRow(modelId: m.id, windowDuration: durationSeconds, stat: stat(m.id),
                                 swatch: nil, accent: color(m.id)) {
                        if m.status == .recorded {
                            Self.accuracyText(m.typicalAbsError)
                        } else {
                            Text(Self.statusText(m.status))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if idx != otherModels.indices.last {
                        Divider().opacity(0.25).padding(.leading, 34)
                    }
                }
            }
        }
    }

    /// Where a model without a record stands, in the accuracy column.
    static func statusText(_ status: ArenaModelListing.Status) -> String {
        switch status {
        case .recorded: return "—"
        case let .scoring(cycles, floor): return "scoring your history · \(cycles) of \(floor) cycles"
        case .downloading: return "downloading"
        case let .declined(reason): return reason
        }
    }
}

/// One row of the compare sheet's model list: the line's swatch, the name
/// (with why it has no line, when it hasn't), its info button, the "on the
/// dashboard" badge, then whatever the list puts on the right. The drawn
/// models and "More models" share it, so the two halves can't drift apart.
private struct ModelListRow<Trailing: View>: View {
    let modelId: String
    let windowDuration: TimeInterval
    let stat: EngineSelfEval.Accuracy.MethodStat?
    /// Nil: a model with no line slot; the space stays, so names align.
    let swatch: Color?
    /// The model's colour, for the badge and the selected row's tint.
    let accent: Color
    var isSelected = false
    var note: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(swatch ?? .clear)
                .frame(width: 14, height: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(BurnTrajectory.displayName(modelId))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            if let summary = BurnTrajectory.summary(modelId) {
                PacerInfoButton(help: summary) {
                    ModelInfoContent(modelId: modelId, windowDuration: windowDuration, stat: stat)
                }
            }
            if isSelected {
                Text("on the dashboard").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .foregroundStyle(accent)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accent.opacity(0.07))
                : nil
        )
    }
}

/// Every model's info popover for one window, side by side — `make
/// render-live`'s `modelInfo` page, because a popover cannot be rendered
/// off-screen. Reads the scope's engine the way the sheet does.
struct ModelInfoGallery: View {
    let windowKey: String
    let duration: TimeInterval
    let limitAccountId: String?
    @Environment(\.usageEngines) private var engines
    @State private var accuracy: EngineSelfEval.Accuracy?

    var body: some View {
        // The engine's methods, then every arena model that forecasts this
        // window, recorded or not (the sheet's "More models"): the gallery
        // shows what the sheet can.
        let target: ArenaTarget? = windowKey == RateLimitWindowName.fiveHour ? .meterFiveHour
            : windowKey == RateLimitWindowName.sevenDay ? .meterSevenDay : nil
        let ids = RateLimitRoster.engineIds
            + (target.map { ArenaRoster.standard.specs(for: $0).map(\.name).sorted() } ?? [])
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 330), alignment: .top)],
                  alignment: .leading, spacing: 12) {
            ForEach(ids, id: \.self) { id in
                ModelInfoContent(modelId: id, windowDuration: duration,
                                 stat: accuracy?.methods.first { $0.method == id })
                    .padding(14)
                    .frame(width: 300, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            }
        }
        .padding(16)
        .task {
            guard let engine = engines?.engine(forAccount: limitAccountId) else { return }
            let surface = EngineSelfEval.rlSurface(windowKey)
            accuracy = await askEngine { await engine.selfEvalAccuracy(surface: surface) }
        }
    }
}

/// The compare sheet's info popover for one model: how it works, then its
/// record on this window split by how far through the window the call was
/// made. Late calls are always closer, so the split shows where a model earns
/// or loses its overall number.
private struct ModelInfoContent: View {
    let modelId: String
    let windowDuration: TimeInterval
    let stat: EngineSelfEval.Accuracy.MethodStat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(BurnTrajectory.displayName(modelId))
                .font(.system(size: 13, weight: .semibold))
            if let how = BurnTrajectory.howItWorks(modelId, windowDuration: windowDuration) {
                Text(how)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stat, !stat.byStage.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TYPICAL ACCURACY, \(stat.periods) PAST CYCLES")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    ForEach(stat.byStage, id: \.stage) { s in
                        HStack {
                            Text(Self.label(s.stage))
                            Spacer()
                            Text(String(format: "within ±%.0f%%", s.typicalAbsError))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                }
            } else {
                Text("No completed cycles scored yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func label(_ stage: EngineSelfEval.Accuracy.Stage) -> String {
        switch stage {
        case .early: return "Early, 20–40% through"
        case .middle: return "Middle, 50–70% through"
        case .late: return "Late, 80–90% through"
        }
    }
}
