import SwiftUI
import PacerUI

/// Custom "About Pacer" window. Replaces `orderFrontStandardAboutPanel`
/// — the system panel renders a bare icon + version + credits blob with
/// no affordance to reach the project, file a bug, or star the repo,
/// which for an open-source utility is the whole point of an About box.
///
/// Shown via a singleton `Window(id: "about")` scene in `PacerApp`, so
/// the menu item reuses the one window instead of stacking panels. Uses
/// the shared `PacerUI` design tokens so it reads as the same surface as
/// the dashboard rather than a one-off.
struct AboutView: View {
    // Project links. Hard-coded rather than read from a plist: these are
    // the canonical home for the open-source project and don't vary per
    // build the way the version strings do.
    private static let repoURL = URL(string: "https://github.com/EricAndrechek/Pacer")!
    private static let issuesURL = URL(string: "https://github.com/EricAndrechek/Pacer/issues")!
    private static let releasesURL = URL(string: "https://github.com/EricAndrechek/Pacer/releases")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Eric Andrechek"
    }

    var body: some View {
        VStack(spacing: 18) {
            // Logo. The asset already carries the purple→blue gradient
            // badge, so it needs no extra chrome beyond a soft shadow to
            // lift it off the window background.
            Image("PacerLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            VStack(spacing: 5) {
                Text("Pacer")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text("Native macOS tracking for Claude Code usage.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)

            // Project links. A star nudge first (the ask), then the two
            // destinations a user actually reaches for from an About box.
            HStack(spacing: 10) {
                AboutLinkButton(title: "Star", systemImage: "star.fill", url: Self.repoURL)
                AboutLinkButton(title: "Issues", systemImage: "ladybug.fill", url: Self.issuesURL)
                AboutLinkButton(title: "Releases", systemImage: "shippingbox.fill", url: Self.releasesURL)
            }
            .padding(.top, 2)

            Divider()
                .frame(width: 220)
                .padding(.vertical, 2)

            VStack(spacing: 6) {
                Text("Storage is local to this Mac. The only network egress is the OAuth poll to api.anthropic.com.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
                Text(copyright)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        // Generous top padding clears the floating traffic-light buttons
        // that the `.hiddenTitleBar` window style leaves overlaid on the
        // content's top-left corner.
        .padding(.top, 38)
        .padding(.horizontal, 40)
        .padding(.bottom, 32)
        .frame(width: 400)
        .background(.background)
    }
}

// MARK: - Link button

/// A compact bordered link with an SF Symbol over its label. Wraps
/// `Link` so it opens the destination in the user's browser and inherits
/// the standard hover/press states, while a `VStack` icon-over-text
/// layout keeps the three project links narrow enough to sit in one row.
private struct AboutLinkButton: View {
    let title: String
    let systemImage: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(width: 76, height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PacerDesign.cardStroke, lineWidth: 1)
        )
        .help(url.absoluteString)
    }
}
