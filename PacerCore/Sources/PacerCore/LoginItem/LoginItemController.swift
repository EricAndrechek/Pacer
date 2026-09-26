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
/// **Pacer never registers on its own initiative.** The user has to flip
/// "Open at Login" in Settings explicitly. This matches the project's
/// composable-integrations guidance — long-lived system changes
/// require explicit consent. First-time registration triggers a
/// System Settings → Login Items approval prompt.
///
/// **But it keeps the user's choice.** Eric found the setting off on
/// 2026-09-25, sure it had been on. macOS's record showed no registration
/// at all before he re-enabled it. `make install` and `make reinstall` were
/// tested and don't drop it. What did can't be recovered: the logs don't
/// reach back to the macOS 27 upgrade on Sep 15, and before May "at login" was
/// a separate daemon that the single-binary rewrite retired. So the choice is
/// now recorded when the toggle flips, and `reconcileAtLaunch` restores a
/// registration macOS dropped, logging what it found either way.
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

    // MARK: - The user's choice

    static let choiceKey = "loginItem.userChoice"

    /// What the user last chose with the toggle, or nil if they never have.
    public static func recordedChoice(in defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: choiceKey) as? Bool
    }

    static func record(_ choice: Bool, in defaults: UserDefaults) {
        defaults.set(choice, forKey: choiceKey)
    }

    /// The toggle's path: register or unregister, and remember which.
    public static func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) async throws {
        record(on, in: defaults)
        if on { try register() } else { try await unregister() }
        Log.write("LoginItem", "turned \(on ? "on" : "off") in Settings; status \(currentStatus().rawValue)")
    }

    /// Whether the toggle should read as on. `.requiresApproval` is
    /// registered and waiting for the user in System Settings, so it is on,
    /// with the approval prompt beside it rather than looking switched off.
    public static func isOn(_ status: Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    // MARK: - Launch

    public enum LaunchDecision: Equatable, Sendable {
        /// Nothing to do: it matches the user's choice, or they never made one.
        case leave
        /// Registered but no choice recorded yet (set before choices were
        /// kept): adopt it as the user's choice, so it is protected from now on.
        case adoptAsChoice
        /// The user chose on, and macOS has no registration: restore it.
        case reRegister
    }

    /// What launch should do, given the recorded choice and macOS's status.
    ///
    /// Only a *missing* registration is restored. `.requiresApproval` is the
    /// user's move in System Settings, and re-registering over it would just
    /// prompt again.
    public static func decision(choice: Bool?, status: Status) -> LaunchDecision {
        switch (choice, status) {
        case (nil, .enabled), (nil, .requiresApproval): return .adoptAsChoice
        case (true, .notRegistered), (true, .notFound):  return .reRegister
        default:                                          return .leave
        }
    }

    /// Run once per launch: log the status, and act on `decision`.
    ///
    /// The line is written every launch on purpose. The investigation above
    /// stalled because nothing recorded when the registration disappeared;
    /// with this, a future loss shows up between two launches in the log.
    public static func reconcileAtLaunch(defaults: UserDefaults = .standard) {
        let status = currentStatus()
        let choice = recordedChoice(in: defaults)
        let chose = choice.map { $0 ? "on" : "off" } ?? "none recorded"
        switch decision(choice: choice, status: status) {
        case .leave:
            Log.write("LoginItem", "status \(status.rawValue); your choice: \(chose)")
        case .adoptAsChoice:
            record(true, in: defaults)
            Log.write("LoginItem", "status \(status.rawValue); recorded as your choice")
        case .reRegister:
            do {
                try register()
                Log.write("LoginItem", "you chose on but macOS had no registration "
                    + "(\(status.rawValue)); registered again, status now \(currentStatus().rawValue)")
            } catch {
                Log.write("LoginItem", "you chose on but macOS had no registration "
                    + "(\(status.rawValue)); registering again failed: \(error)")
            }
        }
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
