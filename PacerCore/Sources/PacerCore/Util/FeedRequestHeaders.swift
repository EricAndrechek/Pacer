import Foundation

/// Request headers on Pacer's two periodic requests to its own site, the
/// Sparkle appcast and the curated price history, so the site can count active
/// Macs and versions (owner's decision, 2026-11-25; `docs/telemetry-plan.md`,
/// "Feed requests").
///
/// - `X-Pacer-Check`: `manual` only for a check the user started; everything
///   else is `scheduled`.
/// - `X-Pacer-Since-Last-Check`: a coarse bucket of the time since the
///   previous request of this kind (`never` when there was none).
/// - `X-Pacer-Version` (price history only; the appcast's User-Agent already
///   carries it).
/// - `X-Pacer-Id`: the install id, **only** while the Usage-data toggle is on.
///   `idHeader` takes the toggle as a closure and is called per request, so a
///   change applies to the very next one. PacerCore does not know where the
///   id comes from: the app supplies it.
public enum FeedRequestHeaders {

    public enum Check: String, Sendable { case manual, scheduled }

    public static let checkField = "X-Pacer-Check"
    public static let sinceField = "X-Pacer-Since-Last-Check"
    public static let versionField = "X-Pacer-Version"
    public static let idField = "X-Pacer-Id"

    /// Bucket edges are inclusive at the lower bound: exactly 1 h is `1-6h`.
    public static func sinceBucket(since last: Date?, now: Date) -> String {
        guard let last else { return "never" }
        let hours = now.timeIntervalSince(last) / 3600
        switch hours {
        case ..<1: return "lt1h"      // includes a clock that moved backwards
        case ..<6: return "1-6h"
        case ..<12: return "6-12h"
        case ..<24: return "12-24h"
        case ..<168: return "1-7d"
        default: return "gt7d"
        }
    }

    /// The headers every request carries. `id` is added by the caller only
    /// when `idHeader` returned one.
    public static func headers(check: Check, since last: Date?, now: Date = Date(),
                               version: String? = nil, id: [String: String] = [:]) -> [String: String] {
        var out = [checkField: check.rawValue, sinceField: sinceBucket(since: last, now: now)]
        if let version, !version.isEmpty { out[versionField] = version }
        for (k, v) in id { out[k] = v }
        return out
    }

    /// `X-Pacer-Id` iff this is the user's own app, the Usage-data toggle is on
    /// and an id already exists. Every input is a closure read right now.
    public static func idHeader(usageAllowed: () -> Bool, isNormalLaunch: () -> Bool,
                                installId: () -> String?) -> [String: String] {
        guard isNormalLaunch(), usageAllowed(),
              let id = installId(), !id.isEmpty else { return [:] }
        return [idField: id]
    }
}

/// The price-history fetch's header source. The app installs a provider at
/// launch that adds the id; the default carries only version, check kind and
/// the since bucket.
public final class FeedRequestHeaderProvider: @unchecked Sendable {
    public typealias Provider = @Sendable () -> [String: String]

    public static let priceHistory = FeedRequestHeaderProvider()

    private let lock = NSLock()
    private var extra: Provider = { [:] }

    /// Extra headers merged over the defaults on every request (called per request).
    public func setExtra(_ provider: @escaping Provider) {
        lock.lock(); extra = provider; lock.unlock()
    }

    func currentExtra() -> [String: String] {
        lock.lock(); let p = extra; lock.unlock()
        return p()
    }

    /// Defaults plus the app's extras; the price fetch is always `scheduled`.
    func headers(lastFetch: Date?, now: Date = Date(), version: String? = nil) -> [String: String] {
        FeedRequestHeaders.headers(check: .scheduled, since: lastFetch, now: now,
                                   version: version, id: currentExtra())
    }
}
