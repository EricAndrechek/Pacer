import Foundation
import Synchronization

/// Tallies for the ways reading another tool's credentials can fail: Claude
/// Desktop's encrypted token cache, cswap's saved logins and usage file, a
/// pinned profile's keychain item. Each is an in-memory counter
/// (`TelemetryCounters`) that the daily check-in sends, named
/// `cred.<source>.<kind>` where `kind` is one of the fixed words below, never
/// the underlying message (which can carry a path or a status string).
///
/// What this tells us: Anthropic changed Desktop's storage format
/// (`decrypt_failed`), a keychain prompt keeps being declined
/// (`access_denied`), or cswap changed its file layout (`usage_unreadable`).
/// Each of those silently turns a user's data off with no other trace.
public enum CredentialTelemetry {

    private static let noted = Mutex<Set<String>>([])

    public static func note(_ source: String, _ kind: String) {
        TelemetryCounters.add("cred.\(source).\(kind)")
    }

    /// Like `note`, but at most once per launch per (source, kind), for the
    /// failure that would otherwise be re-hit by every read of a file that
    /// stays broken.
    public static func noteOnce(_ source: String, _ kind: String) {
        let first = noted.withLock { $0.insert("\(source).\(kind)").inserted }
        if first { note(source, kind) }
    }

    /// Forget the once-per-launch memory (tests).
    static func resetLaunchState() { noted.withLock { $0.removeAll() } }

    /// The kind for a keychain reason string from `ParkedCredentialStore`
    /// ("access denied", "could not run security (N)", "security exited N").
    static func keychainKind(reason: String) -> String {
        if reason.hasPrefix("access denied") { return "access_denied" }
        if reason.hasPrefix("could not run") { return "spawn_failed" }
        if reason.hasPrefix("security exited") { return "exit_nonzero" }
        return "other"
    }
}

extension DesktopOAuthError {
    /// The fixed word for this failure, for `cred.desktop.<kind>`.
    var telemetryKind: String {
        switch self {
        case .configNotFound: return "config_not_found"
        case .keychainKeyUnavailable: return "key_unavailable"
        case .keychainAccessDenied: return "access_denied"
        case .decryptFailed: return "decrypt_failed"
        case .noProfileToken: return "no_profile_token"
        }
    }
}
