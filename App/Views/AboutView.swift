import SwiftUI
import Sparkle
import PacerUI

/// Custom "About Pacer" window. Replaces `orderFrontStandardAboutPanel`
/// — the system panel renders a bare icon + version + credits blob with
/// no affordance to reach the project, file a bug, sponsor it, or check
/// for updates, which for an open-source utility is the whole point of
/// an About box.
///
/// Shown via a singleton `Window(id: "about")` scene in `PacerApp`, so
/// the menu item reuses the one window instead of stacking panels. Uses
/// the shared `PacerUI` design tokens so it reads as the same surface as
/// the dashboard rather than a one-off.
struct AboutView: View {
    /// Sparkle updater, threaded through from `PacerApp` so the
    /// "Check for Updates…" action drives the same updater the menu-bar
    /// item uses (a single check-in-flight state across both entry
    /// points).
    let updater: SPUUpdater

    // Project links. Hard-coded rather than read from a plist: these are
    // the canonical home for the open-source project and don't vary per
    // build the way the version strings do.
    private static let repoURL = URL(string: "https://github.com/EricAndrechek/Pacer")!
    private static let sponsorURL = URL(string: "https://github.com/sponsors/EricAndrechek")!
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
        VStack(spacing: 16) {
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
                // Only the marketing version is shown; the build number
                // (a unix-timestamp, meaningful only to Sparkle's update
                // ordering) is tucked into a hover tooltip so it's still
                // available for bug reports without cluttering the line.
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Build \(build)")
                // Reuses the menu item's Sparkle integration (KVO-driven
                // disable while a check is in flight). `.link` style
                // renders it as a quiet hyperlink right under the version
                // — where macOS users look for it — rather than a heavy
                // push button.
                CheckForUpdatesView(updater: updater)
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.top, 1)
            }

            Text("Native macOS tracking for Claude Code usage.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)

            // Project links. Star + Donate (the support pair) lead, then
            // the two destinations a user reaches for from an About box.
            HStack(spacing: 8) {
                AboutLinkButton(title: "Star", systemImage: "star.fill", url: Self.repoURL)
                AboutLinkButton(title: "Donate", systemImage: "heart.fill", url: Self.sponsorURL)
                AboutLinkButton(title: "Issues", systemImage: "ladybug.fill", url: Self.issuesURL)
                AboutLinkButton(title: "Releases", systemImage: "shippingbox.fill", url: Self.releasesURL)
            }
            .padding(.top, 2)

            Divider()
                .frame(width: 240)
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
        .padding(.horizontal, 36)
        .padding(.bottom, 32)
        .frame(width: 400)
        .background(.background)
    }
}

// MARK: - Link button

/// A compact bordered link with an SF Symbol over its label. Wraps
/// `Link` so it opens the destination in the user's browser and inherits
/// the standard hover/press states, while a `VStack` icon-over-text
/// layout keeps the four project links narrow enough to sit in one row.
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
            .frame(width: 72, height: 54)
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
