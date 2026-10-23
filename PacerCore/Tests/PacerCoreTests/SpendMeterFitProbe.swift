import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The spend → meter fit (#317) on a COPY of a real store. Opt-in:
///
///     mkdir -p /tmp/fitprobe && cp -c ~/Library/Group\ Containers/…/pacer.sqlite* /tmp/fitprobe/
///     PACER_FIT_PROBE=/tmp/fitprobe/pacer.sqlite swift test --package-path PacerCore --filter SpendMeterFitProbe
///
/// Runs the daily job against the copy (it writes there, so the live store is
/// refused), then prints per account and window: the pooled rate and its R²,
/// the per-model fit's R² and RMSE, each model's rate relative to Opus 5.5,
/// the two off-this-Mac measures, and how well the stored rates reproduce
/// each day's meter rise.
///
/// `PACER_FIT_PROBE_SPAN=2026-09-18...2026-10-22` (local days, inclusive)
/// fits that span as well, without writing, to compare with the research
/// harness's longer-span numbers.
@Suite("Spend → meter fit probe", .enabled(if: ProcessInfo.processInfo.environment["PACER_FIT_PROBE"] != nil))
struct SpendMeterFitProbe {

    @Test func fitsTheRealStore() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: env["PACER_FIT_PROBE"]!)
        let live = (try? PacerStore.storeURL())?.standardizedFileURL.path
        try #require(url.standardizedFileURL.path != live && !url.path.contains("/Group Containers/"),
                     "point PACER_FIT_PROBE at a copy, not the live store")
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(url: url))

        // Off the main actor, as the app runs it.
        let worker = await Task.detached { SpendMeterFitWorker(modelContainer: container) }.value
        let now = Date()
        let daily = try await worker.refit(now: now)
        print(String(format: "=== daily job: %@, span %@ → %@, %d readings + %d spend rows in %.0f ms",
                     daily.fittedDay, "\(daily.span.start)", "\(daily.span.end)",
                     daily.readingRows, daily.spendRows, daily.elapsed * 1000))
        try await report(daily, worker: worker)

        let day = daily.fittedDay
        let stored = try ModelContext(container).fetch(FetchDescriptor<SpendMeterFit>(
            predicate: #Predicate { $0.fittedDay == day }))
        #expect(stored.count == daily.fitted.count)

        if let spec = env["PACER_FIT_PROBE_SPAN"] {
            let parts = spec.components(separatedBy: "...")
            try #require(parts.count == 2, "PACER_FIT_PROBE_SPAN is first...last")
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            let first = try #require(f.date(from: parts[0]))
            let last = try #require(f.date(from: parts[1]))
            let end = try #require(Calendar.current.date(byAdding: .day, value: 1, to: last))
            let long = try await worker.refit(now: now, span: DateInterval(start: first, end: end), persist: false)
            print(String(format: "=== span %@ → %@ (not stored), %d readings + %d spend rows in %.0f ms",
                         parts[0], parts[1], long.readingRows, long.spendRows, long.elapsed * 1000))
            try await report(long, worker: worker)
        }
    }

    /// One block per account × window.
    private func report(_ r: SpendMeterFitWorker.Report, worker: SpendMeterFitWorker) async throws {
        let since = r.span.start.addingTimeInterval(-SpendMeterFitter.maxPairGap)
        let until = r.span.end.addingTimeInterval(SpendMeterFitter.maxPairGap)
        let spend = try await Self.spend(worker: worker, span: r.span)
        for entry in r.entries {
            let who = "\(entry.accountId.suffix(4)) \(entry.window)"
            guard case .fitted(let fit) = entry.outcome else {
                if case .skipped(let reason) = entry.outcome { print("\(who): not fitted, \(reason)") }
                continue
            }
            let opus = fit.modelRates["claude-opus-5-5"]
            let rates = fit.modelRates.sorted { $0.value > $1.value }.map { model, rate in
                let rel = opus.map { $0 > 0 ? String(format: " (%.2f×)", rate / $0) : "" } ?? ""
                return String(format: "%@ %.4f%@", model, rate, rel)
            }.joined(separator: ", ")
            print(String(format: "%@: pooled %.4f pts/$ R² %.3f | per-model R² %.3f rmse %.2f | hours %d (active %d) | rise %.0f on $%.0f",
                         who, fit.pooledRate, fit.pooledR2, fit.r2, fit.rmse, fit.hours, fit.activeHours,
                         fit.totalRise, fit.totalSpendUSD))
            print("    rates: \(rates)")
            print(String(format: "    off this Mac: NNLS intercept %.3f pts/h = %.1f%% of rise; no-spend hours %.1f%% | unfitted $%.0f",
                         fit.interceptPerHour, 100 * fit.interceptShare, 100 * fit.noSpendRiseShare,
                         fit.unfittedSpendUSD))

            // Each day's rise against what the stored rates say it was.
            let windows = await worker.readings(account: entry.accountId, since: since, until: until)
            guard let w = windows.first(where: { $0.key == entry.window }) else { continue }
            let counts = SpendMeterFitter.capCounts(modelId: w.capModelId, displayName: w.capModelName)
            let rise = SpendMeterFitter.hourlyRise(readings: w.readings, duration: w.duration,
                                                    span: r.span, timeZone: .current)
            var byDay: [String: (actual: Double, predicted: Double, hours: Int)] = [:]
            var spendByHour: [LocalHour: [String: Double]] = [:]
            for s in spend[entry.accountId] ?? [] {
                spendByHour[LocalHour(date: s.date, hour: s.hour), default: [:]][s.model, default: 0] += s.costUSD
            }
            var spentInRows: [String: Double] = [:]
            for (hour, observed) in rise {
                let byModel = spendByHour[hour] ?? [:]
                var predicted = fit.interceptPerHour * observed.watched
                for (model, cost) in byModel where counts?(model) ?? true {
                    spentInRows[model, default: 0] += cost
                    predicted += cost * (fit.modelRates[model] ?? fit.pooledRate)
                }
                let prior = byDay[hour.date] ?? (0, 0, 0)
                byDay[hour.date] = (prior.actual + observed.rise, prior.predicted + predicted, prior.hours + 1)
            }
            let errors = byDay.values.map { abs($0.actual - $0.predicted) }.sorted()
            let within = byDay.values.filter {
                abs($0.actual - $0.predicted) <= 2 * fit.rmse * Double($0.hours).squareRoot()
            }.count
            let meanDay = byDay.values.reduce(0) { $0 + $1.actual } / Double(max(1, byDay.count))
            let collapsedRate = fit.modelRates.reduce(0.0) { $0 + $1.value * (spentInRows[$1.key] ?? 0) }
                / max(1e-9, spentInRows.values.reduce(0, +))
            print(String(format: "    days: %d, mean rise %.1f; |actual − fitted| median %.1f, p90 %.1f, worst %.1f; %d/%d within 2·rmse·√hours",
                         byDay.count, meanDay, errors.isEmpty ? 0 : errors[errors.count / 2],
                         errors.isEmpty ? 0 : errors[min(errors.count - 1, errors.count * 9 / 10)],
                         errors.last ?? 0, within, byDay.count))
            print(String(format: "    per-model fit collapsed to one factor: %.4f pts/$ (+ intercept %.4f) vs pooled %.4f",
                         collapsedRate, fit.interceptPerHour * Double(fit.hours) / max(1e-9, fit.totalSpendUSD),
                         fit.pooledRate))
        }
    }

    /// The same bounded spend read the job makes.
    private static func spend(worker: SpendMeterFitWorker, span: DateInterval) async throws -> [String: [HourlySpend]] {
        let container = worker.modelContainer
        return try await MainActor.run {
            let startKey = TokenSample.formatDate(span.start)
            let endKey = TokenSample.formatDate(span.end)
            let rows = try ModelContext(container).fetch(FetchDescriptor<AccountHourlyAggregate>(
                predicate: #Predicate { $0.date >= startKey && $0.date <= endKey }))
            var out: [String: [HourlySpend]] = [:]
            for row in rows {
                out[row.accountId, default: []].append(
                    HourlySpend(date: row.date, hour: row.hour, model: row.model, costUSD: row.totalCostUSD))
            }
            return out
        }
    }
}
