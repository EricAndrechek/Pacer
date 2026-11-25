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
    /// Why a download failed or a cycle ended in an error: the error's
    /// `error_<domain>_<code>` form, plus `:` and the same for its underlying
    /// error when it has one. Never a description.
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
        /// "Update to … — Restart" items (`UpdateCopy`).
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

    /// The reason for a failed download or a failed cycle: the error's domain
    /// tail and code, then its `NSUnderlyingErrorKey` error's, joined by `:`.
    /// No description.
    ///
    /// Not `/`: every string that leaves goes through `TelemetryScrubber`,
    /// which redacts any 40+ run of `[A-Za-z0-9+/_-]` as a likely token, and
    /// `error_sparkle_2001/error_nsurlerrordomain_-1009` is 47 such characters.
    /// It arrived as `<redacted>`. `:` ends the run, and each half stays under
    /// 40 for every domain and code Sparkle and Foundation use.
    public static func errorDetail(domain: String, code: Int,
                                   underlyingDomain: String? = nil, underlyingCode: Int? = nil) -> String {
        let top = result(forErrorDomain: domain, code: code)
        guard let underlyingDomain, let underlyingCode else { return top }
        return top + ":" + result(forErrorDomain: underlyingDomain, code: underlyingCode)
    }

    /// What Sparkle's "cycle finished" callback reports. `SUNoUpdateError` is
    /// the "you're up to date" answer, not a failure. Any other error keeps its
    /// underlying error's domain and code as the detail: Sparkle wraps a failed
    /// appcast fetch and a failed download in the same `SUDownloadError`
    /// (2001), and only the underlying `NSURLErrorDomain` code says whether the
    /// Mac was offline, timed out, or got an HTTP error.
    public static func recordEndOfCycle(domain: String, code: Int,
                                        underlyingDomain: String? = nil, underlyingCode: Int? = nil,
                                        now: Date = Date(), store: UserDefaults = PacerPreferences.store) {
        if domain == sparkleErrorDomain, code == sparkleNoUpdateCode {
            record(.noUpdate, endOfCycle: true, now: now, store: store)
            return
        }
        let detail = underlyingDomain != nil && underlyingCode != nil
            ? errorDetail(domain: domain, code: code, underlyingDomain: underlyingDomain, underlyingCode: underlyingCode)
            : nil
        record(result(forErrorDomain: domain, code: code), error: detail, endOfCycle: true, now: now, store: store)
    }

    /// Whole hours since the last result was recorded, for the check-in: nil
    /// until Sparkle has said anything. `found` or `ready_to_install` that is
    /// days old is the stuck-update signal; without the age, a result recorded
    /// a minute ago and one recorded a week ago read the same. A clock that went
    /// backwards reads 0.
    public static func resultAgeHours(now: Date = Date(), store: UserDefaults = PacerPreferences.store) -> Int? {
        guard store.string(forKey: resultKey) != nil,
              let at = store.object(forKey: atKey) as? Date else { return nil }
        return max(0, Int(now.timeIntervalSince(at) / 3600))
    }

    /// What the check-in reports: nil until Sparkle has said anything.
    public static func last(store: UserDefaults = PacerPreferences.store) -> (result: String, version: String?, error: String?, delta: Bool?)? {
        guard let result = store.string(forKey: resultKey) else { return nil }
        let delta = store.object(forKey: deltaKey) as? Bool
        return (result, store.string(forKey: versionKey), store.string(forKey: errorKey), delta)
    }
}
