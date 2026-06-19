import SwiftUI
import PacerCore
import PacerUI

/// First-run / post-upgrade nudge to turn on Claude Desktop credentials.
///
/// A tinted dashboard banner (like `WelcomeCard`) shown when Claude Desktop
/// is installed with a token cache but the toggle is off.
///
///   - **Enable** turns it on for good and reads Desktop once in the
///     background to surface the one-time "Claude Safe Storage" keychain
///     approval in context (the system dialog is the approval UI; Settings →
///     Authentication is the recovery path if denied).
///   - **Not now** dismisses it permanently (the nudge never reappears). The
///     feature stays reachable in Settings → Authentication, which the copy
///     points to — so nothing is lost silently.
///
/// Suppressed in screenshot mode so it never leaks into README shots.
struct DesktopCredentialPrompt: View {
    @AppStorage(PacerSettings.Key.desktopCredentialsEnabled, store: PacerSettings.store)
    private var enabled: Bool = false
    @AppStorage(PacerSettings.Key.desktopOnboardingDismissed, store: PacerSettings.store)
    private var dismissed: Bool = false

    // Cheap, file-only check (no keychain prompt); snapshot once per view.
    private let desktopAvailable = DesktopOAuth.isClaudeDesktopAvailable

    var body: some View {
        if enabled || dismissed || !desktopAvailable || ScreenshotMode.isActive {
            EmptyView()
        } else {
            banner
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 8) {
                Text("Also track Claude Desktop")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Read its credential (read-only) so Pacer keeps updating outside the Claude Code CLI. One-time keychain approval — turn it on or off anytime in Settings → Authentication.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Enable") { enable() }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { dismissed = true }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 2)
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

    private func enable() {
        enabled = true
        // Surface the one-time keychain approval now, in context. Result is
        // immaterial — the toggle is on; the poller uses Desktop once approved
        // and Settings → Authentication is the recovery path. Off-main so the
        // briefly-blocking `security` subprocess doesn't stall the UI.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = DesktopOAuth().read()
        }
    }
}
