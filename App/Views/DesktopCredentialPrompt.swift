import SwiftUI
import PacerCore
import PacerUI

/// First-run / post-upgrade nudge to turn on Claude Desktop credentials.
///
/// Renders a tinted banner at the top of the dashboard (mirroring
/// `WelcomeCard`) when ALL of:
///   - we haven't offered it yet (`desktopOnboardingOffered` is false — so
///     fresh installs AND existing users upgrading into this build see it
///     exactly once),
///   - Claude Desktop is installed with a token cache, and
///   - the toggle isn't already on.
///
/// Either action marks it offered so it never nags again. "Enable" flips the
/// toggle and reads Desktop once in the background to surface the one-time
/// "Claude Safe Storage" keychain approval in context; if the user denies it,
/// the toggle is still on and they can re-approve via the Settings → Authentication
/// "Test" button (the system dialog, not this banner, is the approval UI).
struct DesktopCredentialPrompt: View {
    @AppStorage(PacerSettings.Key.desktopCredentialsEnabled, store: PacerSettings.store)
    private var enabled: Bool = false
    @AppStorage(PacerSettings.Key.desktopOnboardingOffered, store: PacerSettings.store)
    private var offered: Bool = false

    // Snapshot the (cheap, file-only) availability check once per view so
    // body re-evaluations don't re-stat the config file.
    private let desktopAvailable = DesktopOAuth.isClaudeDesktopAvailable

    var body: some View {
        if offered || enabled || !desktopAvailable {
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
                Text("You have Claude Desktop installed. Let Pacer read its credential (read-only) so your usage keeps updating even when you're not using the Claude Code CLI — and stays live through Claude Code's token gaps. It triggers a one-time keychain approval; you can change this any time in Settings → Authentication.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Enable") { enable() }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { offered = true }
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
        offered = true
        // Surface the one-time keychain approval now, in context. The read's
        // result is immaterial here — the toggle is already on; the poller
        // will use Desktop once approved, and Settings → Authentication is the
        // recovery path if the user denies. Run off-main so the (briefly
        // blocking) `security` subprocess doesn't stall the UI.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = DesktopOAuth().read()
        }
    }
}
