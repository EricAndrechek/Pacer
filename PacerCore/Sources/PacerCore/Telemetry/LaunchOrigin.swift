import Foundation

/// Whether a launch came from the login item or from someone opening the app.
/// Answers "does 'Open at Login' actually start Pacer for the people who turned
/// it on", which the login-item toggle alone cannot: it says what was asked
/// for, not what happened at the last boot.
///
/// The app reads the launch Apple event (`keyAELaunchedAsLogInItem`) and
/// passes plain values in; the decision and the tallies are here so they can
/// be tested.
public enum LaunchOrigin: String, Sendable {
    case login, manual

    public static let loginKey = "pacer.telemetry.lifecycle.launches_login"
    public static let manualKey = "pacer.telemetry.lifecycle.launches_manual"

    /// A boot this recent, with the login item registered, counts as the
    /// login item's doing even when macOS sent no marker. `SMAppService`
    /// launches do not always carry the legacy Apple-event flag, so without
    /// this a modern login item would read as manual. The cost is that someone
    /// who opens Pacer by hand within five minutes of a boot, with the login
    /// item on, is counted as a login launch; for a yes/no question across
    /// Macs that blur is acceptable.
    public static let loginGrace: TimeInterval = 300

    public static func classify(appleEventSaysLogin: Bool, loginItemEnabled: Bool,
                                secondsSinceBoot: TimeInterval) -> LaunchOrigin {
        if appleEventSaysLogin { return .login }
        if loginItemEnabled, secondsSinceBoot >= 0, secondsSinceBoot < loginGrace { return .login }
        return .manual
    }

    /// The tally for one launch.
    public func record(store: UserDefaults = PacerPreferences.store) {
        let key = self == .login ? Self.loginKey : Self.manualKey
        store.set(store.integer(forKey: key) + 1, forKey: key)
    }

    /// Launches since the last call, cleared. For the daily check-in.
    public static func drain(store: UserDefaults = PacerPreferences.store) -> (login: Int, manual: Int) {
        let counts = (store.integer(forKey: loginKey), store.integer(forKey: manualKey))
        store.set(0, forKey: loginKey)
        store.set(0, forKey: manualKey)
        return counts
    }
}
