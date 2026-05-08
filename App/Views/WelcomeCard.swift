import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// First-run welcome banner. Renders at the top of the dashboard while
/// the SwiftData store has zero `TokenSample` and zero `RateLimitSample`
/// rows; disappears the moment any data lands. We deliberately don't
/// add a "dismiss" action — the goal is to communicate state, not
/// persist UI chrome.
///
/// Visually it's a tinted banner rather than a full-fat card so it
/// reads as ephemeral and doesn't compete with the hero strip below.
struct WelcomeCard: View {
    // Existence-only probes capped at 1 row each — without fetchLimit,
    // an empty-store check would still materialize the full table on
    // every SwiftData save in steady state.
    @Query(WelcomeCard.tokenProbe) private var tokenSamples: [TokenSample]
    @Query(WelcomeCard.rateLimitProbe) private var rateLimits: [RateLimitSample]

    private static let tokenProbe: FetchDescriptor<TokenSample> = {
        var d = FetchDescriptor<TokenSample>()
        d.fetchLimit = 1
        return d
    }()

    private static let rateLimitProbe: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>()
        d.fetchLimit = 1
        return d
    }()

    private var hasAnyData: Bool {
        !tokenSamples.isEmpty || !rateLimits.isEmpty
    }

    var body: some View {
        if hasAnyData {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 16) {
                Image("PacerLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Pacer")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Tracking your Claude Code usage in realtime. On first launch Pacer scans every JSONL transcript in `~/.claude/projects` so you start with the data you already have. Numbers will appear within seconds of any Claude Code activity.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            )
        }
    }
}
