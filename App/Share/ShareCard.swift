import SwiftUI
import Charts
import PacerCore
import PacerUI

/// Shareable-image layout constants. The card renders at a fixed point
/// width so the on-screen popover preview and the exported PNG are the
/// exact same composition — the exporter just rasterizes the same view
/// at a higher `scale`. Treat this as "what you see is what you send."
enum ShareCardLayout {
    static let width: CGFloat = 600
    static let chartHeight: CGFloat = 220
    static let padding: CGFloat = 28
    static let corner: CGFloat = 22
}

// MARK: - Reusable branded chrome

/// One legend entry under the chart ("Your usage" / "Ideal pace").
struct ShareLegendItem: Identifiable {
    enum Style { case solid, dashed }
    let label: String
    let color: Color
    let style: Style
    var id: String { label }
}

/// A pace/usage status tag ("On pace", "Ahead of pace", …).
struct ShareStatus {
    let text: String
    let color: Color
}

/// The branded "hero card" frame every shareable chart image is poured
/// into: title + headline stat + status chip up top, the blown-up chart
/// in the middle, a legend + context caption, and a Pacer wordmark
/// footer. Adding a new shareable chart (cost, heatmap) means feeding
/// this the right title/headline/legend and a chart `content` closure —
/// the social-ready chrome comes for free.
///
/// **Why colors are passed an explicit `scheme` instead of reading the
/// environment:** `ImageRenderer` (the export path) inherits no SwiftUI
/// environment and resolves no `NSAppearance`, so dynamic system colors
/// would all flatten to their light variant in the PNG. This view bakes
/// every color off the passed-in `ColorScheme` and sets
/// `.environment(\.colorScheme, scheme)` so the SwiftUI-semantic colors
/// inside the chart (`.primary`, `.green`, `.secondary`…) resolve to the
/// same appearance — making the exported image match the preview in both
/// light and dark.
struct ShareCardChrome<ChartContent: View>: View {
    let title: String
    let headline: String
    let headlineSub: String?
    let headlineColor: Color
    let status: ShareStatus?
    let caption: String
    let legend: [ShareLegendItem]
    /// Accent for the faint corner wash — usually the headline band color.
    let accent: Color
    let scheme: ColorScheme
    @ViewBuilder var chart: () -> ChartContent

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart()
                .frame(height: ShareCardLayout.chartHeight)
            infoRow
            Divider().overlay(separator)
            brandRow
        }
        .padding(ShareCardLayout.padding)
        .frame(width: ShareCardLayout.width, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ShareCardLayout.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShareCardLayout.corner, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .environment(\.colorScheme, scheme)
    }

    // MARK: pieces

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                if let status {
                    statusChip(status)
                }
            }
            Spacer(minLength: 12)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(headline)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(headlineColor)
                if let headlineSub {
                    Text(headlineSub)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(subInk)
                }
            }
        }
    }

    private func statusChip(_ s: ShareStatus) -> some View {
        HStack(spacing: 5) {
            Circle().fill(s.color).frame(width: 7, height: 7)
            Text(s.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(s.color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(s.color.opacity(0.14)))
    }

    private var infoRow: some View {
        HStack(spacing: 14) {
            ForEach(legend) { legendSwatch($0) }
            Spacer(minLength: 12)
            Text(caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(subInk)
        }
    }

    private func legendSwatch(_ item: ShareLegendItem) -> some View {
        HStack(spacing: 6) {
            Group {
                if item.style == .dashed {
                    HairLine()
                        .stroke(item.color, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                        .frame(width: 18, height: 2)
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(item.color)
                        .frame(width: 18, height: 3)
                }
            }
            Text(item.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(subInk)
        }
    }

    private var brandRow: some View {
        HStack(spacing: 8) {
            Image("PacerLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text("Pacer")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
            Text("· Claude Code usage, paced")
                .font(.system(size: 12))
                .foregroundStyle(subInk)
            Spacer(minLength: 12)
            Text("ericandrechek.github.io/Pacer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(subInk.opacity(0.85))
        }
    }

    // MARK: explicit color palette (see type doc for the ImageRenderer rationale)

    private var ink: Color {
        scheme == .dark ? Color(white: 0.96) : Color(white: 0.11)
    }
    private var subInk: Color {
        scheme == .dark ? Color(white: 0.64) : Color(white: 0.42)
    }
    private var borderColor: Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
    private var separator: Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }
    private var base: Color {
        scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.13) : Color(white: 0.99)
    }

    private var cardBackground: some View {
        ZStack {
            base
            LinearGradient(
                colors: [accent.opacity(scheme == .dark ? 0.16 : 0.09), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// A single horizontal hairline, for the dashed "ideal pace" legend swatch.
private struct HairLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Pace-chart specialization

/// Everything the share sheet needs to render and name a pace-chart
/// image. Built by `PaceChartCard` from the same `@Query` data the live
/// chart draws, so the share image is the live chart, blown up.
struct PaceSharePayload {
    let title: String
    let data: PaceChartView.Data
    let duration: TimeInterval
    let resetsAt: Date
    let usedPct: Double
    let paceEndPct: Double
    let fileName: String
}

/// Pours a `PaceSharePayload` into the branded chrome: the blown-up
/// `PaceChartView`, a used%/pace% headline colored by pace band, a
/// plain-language status chip, and a "resets …" caption a friend who's
/// never seen Pacer can still read.
struct PaceShareCard: View {
    let payload: PaceSharePayload
    let scheme: ColorScheme

    var body: some View {
        let band = PaceBand(usedPct: payload.usedPct, paceEndPct: payload.paceEndPct)
        ShareCardChrome(
            title: payload.title,
            headline: "\(Int(payload.usedPct.rounded()))%",
            headlineSub: "/ \(Int(payload.paceEndPct.rounded()))% pace",
            headlineColor: band.color,
            status: status(for: band),
            caption: caption,
            legend: [
                ShareLegendItem(label: "Your usage", color: band.color, style: .solid),
                // The reference line renders as Swift Charts' default
                // series color (blue) in both the live app and any
                // captured image — its `.secondary` dash style is dropped
                // for an unstyled single-mark series. Match the legend to
                // what actually draws rather than to the code's intent.
                ShareLegendItem(label: "Ideal pace", color: .blue, style: .solid),
            ],
            accent: band.color,
            scheme: scheme
        ) {
            PaceChartView(data: payload.data, style: .detailed)
        }
    }

    /// Plain-language pace standing. The dashboard codes this purely by
    /// color; a shared image goes to people without that context, so we
    /// spell it out. `.white` (on pace) uses ink rather than the band's
    /// `.primary` so the chip text/dot stay legible against its own wash.
    private func status(for band: PaceBand) -> ShareStatus {
        switch band {
        case .green:  return ShareStatus(text: "Under pace", color: band.color)
        case .white:  return ShareStatus(
            text: "On pace",
            color: scheme == .dark ? Color(white: 0.85) : Color(white: 0.25)
        )
        case .yellow: return ShareStatus(text: "Ahead of pace", color: band.color)
        case .red:    return ShareStatus(text: "Near the limit", color: band.color)
        }
    }

    /// "Resets Mon 3 PM · in 4 days" (7-day) / "Resets 9:14 PM · in 2 hours"
    /// (5-hour). Reuses the shared locale-aware formatters.
    private var caption: String {
        let when: String
        if payload.duration <= 6 * 3600 {
            when = pacerClockTime(payload.resetsAt)
        } else {
            when = pacerWeekdayClock(payload.resetsAt)
        }
        return "Resets \(when) · \(pacerRelative(payload.resetsAt, style: .full))"
    }
}
