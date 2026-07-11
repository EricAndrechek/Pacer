import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Dashboard card for the scoped `limits[]` representation from
/// `/api/oauth/usage` — the per-model weekly windows (and any future
/// scoped/kinded windows) that the two big 5h/7d pace charts don't show.
///
/// **Fully adaptive by construction.** Nothing here enumerates models,
/// kinds, groups, or severities. It reads back whatever the poller
/// persisted for the most recent poll (`latestBatch`), buckets rows by
/// their raw `group`, orders groups by a soft hint (known ones first, then
/// alphabetical), and colors each row by `displayBand` (percent blended
/// with a severity floor). So a new model, a new `kind`, a new `group`, a
/// new `severity`, or a removed limit all render correctly with no code
/// change — a removed limit simply isn't in the latest batch.
///
/// The card hides itself entirely when there's no `limits[]` data (older
/// server, or an account that doesn't get the array yet) rather than
/// showing an empty shell.
struct LimitsCard: View {
    @Query(LimitsCard.recentDescriptor) private var recent: [UsageLimitSample]

    /// The most-recent-poll rows only. All rows from one poll share a
    /// `sampledAt`, so a bounded fetch of the freshest rows always contains
    /// the whole latest batch; `latestBatch()` slices it out.
    private var batch: [UsageLimitSample] { recent.latestBatch() }

    /// Recent rows, newest first. Bounded so the query never scans the full
    /// append-only history; 120 comfortably spans several polls' worth of
    /// limits (a poll currently carries ~3, realistically < 20).
    private static let recentDescriptor: FetchDescriptor<UsageLimitSample> = {
        var d = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 120
        return d
    }()

    var body: some View {
        if batch.isEmpty {
            // No limits[] data — render nothing (don't show an empty card).
            EmptyView()
        } else {
            PacerCard("Rate limits", trailing: { bindingSummary }) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedRows, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow(text: Self.humanize(section.group))
                            ForEach(section.rows, id: \.identity) { row in
                                LimitRowView(row: row)
                            }
                        }
                    }
                }
            } footer: {
                Text("Scoped limits Anthropic reports for this account — including per-model weekly windows. The highlighted row is the one currently binding.")
            }
        }
    }

    // MARK: - Trailing binding summary

    @ViewBuilder
    private var bindingSummary: some View {
        if let binding = batch.filter({ $0.isActive }).max(by: { $0.percent < $1.percent }) {
            Chip(
                text: "\(Self.humanize(binding.group).lowercased()) · \(binding.label) binding",
                systemImage: "target",
                tint: binding.displayBand.color,
                size: .compact
            )
        }
    }

    // MARK: - Grouping (adaptive)

    private struct Section { let group: String; let rows: [UsageLimitSample] }

    /// Bucket the batch by raw `group`, order groups by a soft hint, and
    /// within each group float the binding/active row up then sort by
    /// percent. All ordering is a *display nicety* over an open set — an
    /// unknown group just sorts after the known ones, never breaks.
    private var groupedRows: [Section] {
        let byGroup = Dictionary(grouping: batch, by: { $0.group })
        return byGroup.keys
            .sorted { a, b in
                let ra = Self.groupRank(a), rb = Self.groupRank(b)
                return ra != rb ? ra < rb : a < b
            }
            .map { key in
                let rows = (byGroup[key] ?? []).sorted { l, r in
                    if l.isActive != r.isActive { return l.isActive && !r.isActive }
                    return l.percent > r.percent
                }
                return Section(group: key, rows: rows)
            }
    }

    /// Soft ordering hint for the two groups seen in the wild; everything
    /// else sorts alphabetically after them. NOT an allow-list — an
    /// unranked group renders fine, it just lands later.
    private static func groupRank(_ group: String) -> Int {
        switch group.lowercased() {
        case "session": return 0
        case "weekly":  return 1
        default:        return 100
        }
    }

    /// "weekly_scoped" -> "Weekly Scoped", "session" -> "Session".
    static func humanize(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Row

/// One limit row: label + optional binding marker, a percent read-out, a
/// band-colored progress bar, and a reset caption. Mirrors the "grouped
/// ledger" mockup (docs/mockups/limits-A-grouped-*.png).
private struct LimitRowView: View {
    let row: UsageLimitSample

    private var band: UsageBand { row.displayBand }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if row.isActive {
                    Circle()
                        .fill(band.color)
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(row.label)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                if row.isActive {
                    Chip(text: "binding", tint: .accentColor, size: .compact)
                }
                // Surface an unrecognized *elevated* severity word verbatim
                // so a new server severity is visible, not silently dropped.
                if row.severityValue.isElevated {
                    Chip(
                        text: row.severity.lowercased(),
                        tint: band.color,
                        size: .compact
                    )
                }
                Spacer(minLength: 8)
                Text("\(Int(row.percent.rounded()))%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(band.color)
            }
            LimitBar(fraction: row.percent / 100, color: band.color)
                .frame(height: 6)
            if let caption = resetCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, row.isActive ? 10 : 0)
        .padding(.vertical, row.isActive ? 7 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(row.isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.label), \(Int(row.percent.rounded()))% used\(row.isActive ? ", binding limit" : "")"
        )
    }

    /// Format the reset time. The window length isn't reported per-limit, so
    /// we infer it from the time remaining purely to pick the caption format
    /// (`pacerResetCaption` only uses the duration to choose clock-vs-weekday
    /// at its 6h threshold) — hours-away reads "resets in 2h · 4:19 PM",
    /// days-away reads "resets in 2d · Mon 10 AM". nil resets_at → no caption.
    private var resetCaption: String? {
        guard let resetsAt = row.resetsAt else { return nil }
        let remaining = max(0, resetsAt.timeIntervalSinceNow)
        return pacerResetCaption(resetsAt: resetsAt, durationSeconds: remaining)
    }
}

/// A rounded track + proportional band-colored fill. Kept local (tiny) —
/// the shared `CircularGauge`/`PacerDonut` are radial; this is the linear
/// analogue the limits ledger needs.
private struct LimitBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}
