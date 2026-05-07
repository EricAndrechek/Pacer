import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` — the modern Apple-blessed API for
/// "register the app to open at login." Replaces the old
/// `SMAppService.agent`-based installer that managed a separate
/// LaunchAgent for the retired `PacerDaemon` binary.
///
/// **Why mainApp, not agent**: agent registration assumes a separate
/// helper binary embedded in `Contents/Library/LaunchServices/`.
/// Pacer no longer has one — collection runs inside the main app
/// process. `SMAppService.mainApp.shared` registers the app *itself*
/// for login-time launch, which is the right primitive when the app
/// is its own background service. Stats and Raycast use this same
/// shape (visible as `Library/LoginItems/<helper>.app` in their
/// bundles when registered).
///
/// **Pacer never auto-registers.** The user has to flip "Open at
/// Login" in Settings explicitly. This matches the project's
/// composable-integrations guidance — long-lived system changes
/// require explicit consent. First-time registration triggers a
/// System Settings → Login Items approval prompt.
public enum LoginItemController {

    public enum Status: String, Sendable, CaseIterable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown
    }

    public static func currentStatus() -> Status {
        Self.map(SMAppService.mainApp.status)
    }

    public static func register() throws {
        try SMAppService.mainApp.register()
    }

    public static func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }

    /// Open System Settings → Login Items & Extensions so the user can
    /// approve the registration. Useful when `currentStatus()` returns
    /// `.requiresApproval` (signature drift, first-time approval) —
    /// without this, users have to navigate there manually.
    public static func openSystemSettingsApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> Status {
        switch status {
        case .notRegistered:    return .notRegistered
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .unknown
        }
    }
}
