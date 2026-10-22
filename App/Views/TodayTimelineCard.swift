import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// 24-hour timeline of today's spend. Shows when during the day you
/// were spending — useful for spotting "I had a 4-hour deep
/// session this afternoon" or "early morning was unusually quiet."
///
/// Buckets today's `HourlyAggregate` rows by hour-of-day in the user's
/// local zone and draws them with the shared `PacerStackedPartChart`: each
/// hour stacked by priced part, the costliest hour labelled, and a hover
/// card with the hour's cost, tokens, breakdown and top models.
struct TodayTimelineCard: View {
    /// Optional click handler — clicking any hour drills into today's
    /// day modal. Wired by DashboardView; nil for any other surface.
    let onTodayTap: (() -> Void)?

    init(onTodayTap: (() -> Void)? = nil, scopeAccountId: String? = nil) {
        self.onTodayTap = onTodayTap
        let today = TokenSample.formatDate(Date())
        // Today-scoped `HourlyAggregate` rows are at most 24 × N_models
        // — typically <100. Previously this card queried every
        // `TokenSample` for today (often 3000+) and re-walked them on
        // every scan tick to bucket by hour, calling
        // `effectiveCostUSD(mode:)` per row. The recomputer applies
        // cost mode once at write time, so the read path here is just
        // sum-by-hour over the prebuilt rollup.
        _globalHourly = Query(
            filter: #Predicate<HourlyAggregate> { $0.date == today }
        )
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _scopedHourly = Query(
            filter: #Predicate<AccountHourlyAggregate> {
                $0.date == today && $0.accountId == acct
            }
        )
    }

    @Query private var globalHourly: [HourlyAggregate]
    @Query private var scopedHourly: [AccountHourlyAggregate]
    @State private var scope = UsageScope.shared

    /// Every account, or one. Both queries are live, so switching is a
    /// re-read rather than a recompute.
    private var hourlyRows: [HourlyRow] {
        scope.isAll
            ? globalHourly.map(\.hourlyRow)
            : scopedHourly.map(\.hourlyRow)
    }
    @Query(TodayTimelineCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct Cached {
        /// All 24 hours, quiet ones as empty bars, each with its breakdown
        /// and top models precomputed for the hover card.
        var buckets: [PacerChartBucket] = PacerChartBucket.allHourKeys.map {
            PacerChartBucket(id: $0, breakdown: .zero)
        }
        var peakHour: Int?
        var totalTokens: Int64 = 0
    }

    @MainActor
    private func refreshCache() {
        // Sum across models per hour. Each HourlyAggregate row is one
        // (today, hour, model) bucket pre-applied with the user's
        // current cost mode, so we just add them up.
        var builder = PacerChartBucketBuilder()
        var total: Int64 = 0
        for row in hourlyRows {
            builder.add(PacerChartBucket.hourKey(row.hour), row.costBreakdown, model: row.model)
            total += row.tokens.all
        }
        let buckets = builder.buckets(keys: PacerChartBucket.allHourKeys)
        // The costliest hour, ties to the later one — the same bar the chart
        // labels, so the chip and the label point at one hour.
        let peak = buckets.filter { $0.total > 0 }.max { a, b in
            a.total != b.total ? a.total < b.total : a.id < b.id
        }
        cached = Cached(
            buckets: buckets,
            peakHour: peak.flatMap { Int($0.id) },
            totalTokens: total
        )
    }

    var body: some View {
        // Read here as well as inside `PacerCard`'s stored closures, so a
        // refresh redraws this view, not only the card it hands them to
        // (#140; AGENTS.md, "SwiftUI state and data flow").
        let cached = self.cached
        PacerCard("Today by hour", trailing: {
            // The hovered hour's numbers are in the card floating over the
            // chart; this slot keeps the peak chip and never swaps.
            if let peak = cached.peakHour {
                Chip(
                    text: "peak \(hourLabel(peak, style: .compact))",
                    systemImage: "chart.bar.fill",
                    tint: .accentColor,
                    size: .compact
                )
            }
        }) {
            if cached.totalTokens == 0 {
                Text("No activity logged today yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 100)
            } else {
                // Clicking any hour drills into today's day modal.
                PacerStackedPartChart(
                    cached.buckets, kind: .hour, annotating: 1,
                    onTap: onTodayTap.map { tap in { (_: String) in tap() } }
                )
                .accessibilityLabel("Today's cost by hour")
                .accessibilityHint(onTodayTap != nil ? "Opens today's detailed breakdown" : "")
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
        // The scope is an input to the cache like the data is: without this
        // the card kept the previous account after a switch until a scan
        // ingested something, which on an idle machine may be never (#141).
        .onChange(of: scope.accountId) { _, _ in refreshCache() }
    }

    /// Wrapper that builds a Date for hour-of-day h on today, then
    /// runs it through the shared `pacerHour` helper. Lets the chip
    /// pick up the locale's clock format without re-implementing it.
    private func hourLabel(_ h: Int, style: PacerHourStyle) -> String {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = h
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        return pacerHour(date, style: style)
    }
}
