import Foundation
import ServiceManagement

/// Wraps `SMAppService.agent` for the embedded `PacerDaemon` LaunchAgent.
/// The plist is embedded inside `Pacer.app/Contents/Library/LaunchAgents/`
/// at build time; SMAppService loads it by filename and registers it
/// against the user's launchd, where it persists across reboots and
/// app upgrades.
///
/// **Pacer never auto-registers.** Per the project's
/// composable-integrations and pause-and-confirm guidance, installing a
/// LaunchAgent is a long-lived system change the user must consent to.
/// The App's debug view exposes register/unregister buttons; the daemon
/// itself never registers itself.
public enum LaunchAgentInstaller {

    /// Filename of the LaunchAgent plist embedded in the app bundle.
    /// Must match what's actually copied into
    /// `Contents/Library/LaunchAgents/` by the build phase.
    public static let plistName = "com.ericandrechek.pacer.daemon.plist"

    public enum Status: String, Sendable, CaseIterable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown
    }

    public static func currentStatus() -> Status {
        let agent = SMAppService.agent(plistName: plistName)
        return Self.map(agent.status)
    }

    public static func register() throws {
        let agent = SMAppService.agent(plistName: plistName)
        try agent.register()
    }

    public static func unregister() async throws {
        let agent = SMAppService.agent(plistName: plistName)
        try await agent.unregister()
    }

    /// macOS opens the user's "Login Items & Extensions" preferences
    /// pane to the section where the user can approve/deny the agent.
    /// Useful when `currentStatus()` returns `.requiresApproval` —
    /// without this, users have to navigate there manually.
    public static func openSystemSettingsApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> Status {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
}
