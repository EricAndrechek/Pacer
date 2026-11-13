import Foundation

/// The last thing Sparkle did, kept in the app's defaults for the daily
/// check-in: did the last check find an update, fail to download it, hit an
/// error, or go on to install. "Updates are broken for some Macs" is
/// otherwise invisible: Sparkle reports to nobody.
///
/// Sparkle lives in the app target, so the delegate there passes in plain
/// values; the classification and the storage rules are here, testable. Only
/// an outcome word, Pacer's own release version, and an error's short
/// domain/code leave the Mac (see `result(forErrorDomain:code:)`).
public enum UpdateOutcomeLog {

    public static let resultKey = "pacer.telemetry.update.result"
    public static let versionKey = "pacer.telemetry.update.version"
    public static let atKey = "pacer.telemetry.update.at"
    /// Why a download failed: the error's `error_<domain>_<code>` form, plus
    /// `/` and the same for its underlying error when it has one. Never a
    /// description.
    public static let errorKey = "pacer.telemetry.update.error"
    /// Whether the update being installed is a Sparkle delta (`true`) or a
    /// full download (`false`). Stored only with an install result, so a
    /// Mac whose delta failed and fell back to the full DMG reads `false`.
    public static let deltaKey = "pacer.telemetry.update.delta"

    /// Sparkle's `SUNoUpdateError`: not a failure, the "you're up to date"
    /// answer, which Sparkle delivers through the error channel.
    public static let sparkleNoUpdateCode = 1001
    public static let sparkleErrorDomain = "SUSparkleErrorDomain"

    public enum Outcome: String, Sendable {
        case noUpdate = "no_update"
        case found = "found"
        case downloadFailed = "download_failed"
        /// Installing because someone chose to: Sparkle's own dialog, or the
        /// "Relaunch to Update" item.
        case willInstall = "will_install"
        /// Downloaded and prepared, waiting for a moment Pacer can relaunch
        /// unnoticed (`UpdateInstallPolicy`). A Mac that stays here for days is
        /// one the policy never lets through.
        case readyToInstall = "ready_to_install"
        /// Relaunching to install at such a moment, nobody having asked.
        case idleInstall = "idle_install"
    }

    /// "error_sparkle_2001" for a Sparkle error, "error_<domain tail>_<code>"
    /// for anything else. The domain is cut to its last dotted component and
    /// the identifier alphabet, so a domain can never carry a path or name.
    public static func result(forErrorDomain domain: String, code: Int) -> String {
        let tail = domain == sparkleErrorDomain
            ? "sparkle"
            : String(domain.split(separator: ".").last ?? "unknown")
        let safe = String(tail.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }.prefix(24))
        return "error_\(safe)_\(code)"
    }

    /// Store a result.
    ///
    /// `endOfCycle` marks a result that comes from Sparkle's "cycle finished"
    /// callback, which repeats what an earlier callback already said (a failed
    /// download is followed by a cycle that "ends with an error"). It must not
    /// replace a more specific result recorded in the last two minutes.
    public static func record(_ result: String, version: String? = nil, error: String? = nil,
                              delta: Bool? = nil, endOfCycle: Bool = false, now: Date = Date(), store: UserDefaults = PacerPreferences.store) {
        if endOfCycle,
           let previous = store.string(forKey: resultKey),
           [Outcome.downloadFailed, .willInstall, .idleInstall].map(\.rawValue).contains(previous),
           let at = store.object(forKey: atKey) as? Date, now.timeIntervalSince(at) < 120 {
            return
        }
        store.set(result, forKey: resultKey)
        store.set(now, forKey: atKey)
        // Cleared like the version: a later result without an error must not
        // keep an older failure's reason beside it.
        if let error { store.set(error, forKey: errorKey) } else { store.removeObject(forKey: errorKey) }
        // Cleared the same way: only an install result knows how it arrived.
        if let delta { store.set(delta, forKey: deltaKey) } else { store.removeObject(forKey: deltaKey) }
        // A result without a version (no update, an error before an appcast
        // item) clears the old one so the pair never disagrees.
        if let version, FormatDrift.isReportable(version) {
            store.set(version, forKey: versionKey)
        } else {
            store.removeObject(forKey: versionKey)
        }
    }

    public static func record(_ outcome: Outcome, version: String? = nil, error: String? = nil,
                              delta: Bool? = nil, endOfCycle: Bool = false,
                              now: Date = Date(), store: UserDefaults = PacerPreferences.store) {
        record(outcome.rawValue, version: version, error: error, delta: delta,
               endOfCycle: endOfCycle, now: now, store: store)
    }

    /// The reason for a failed download: the error's domain tail and code,
    /// then its `NSUnderlyingErrorKey` error's, joined by `/`. No description.
    public static func errorDetail(domain: String, code: Int,
                                   underlyingDomain: String? = nil, underlyingCode: Int? = nil) -> String {
        let top = result(forErrorDomain: domain, code: code)
        guard let underlyingDomain, let underlyingCode else { return top }
        return top + "/" + result(forErrorDomain: underlyingDomain, code: underlyingCode)
    }

    /// What the check-in reports: nil until Sparkle has said anything.
    public static func last(store: UserDefaults = PacerPreferences.store) -> (result: String, version: String?, error: String?, delta: Bool?)? {
        guard let result = store.string(forKey: resultKey) else { return nil }
        let delta = store.object(forKey: deltaKey) as? Bool
        return (result, store.string(forKey: versionKey), store.string(forKey: errorKey), delta)
    }
}
