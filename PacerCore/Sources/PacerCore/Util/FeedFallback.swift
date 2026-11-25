import Foundation

/// What Pacer does when pacer.andrechek.com does not answer for the appcast or
/// the curated price history: read the same file from `main` on
/// raw.githubusercontent.com (the exact file the site deploys from, so
/// byte-identical once deployed), say so to Sentry once a day, and go back to
/// the site on the next try. Trust is unchanged: the appcast's EdDSA signatures
/// and the price file's strict decode decide what is believed, not the host.
///
/// The `X-Pacer-*` headers must reach only pacer.andrechek.com, so nothing in
/// here ever adds them to a request for the fallback host.
public enum FeedFallback {

    public enum Feed: String, Sendable { case appcast, priceHistory = "price_history", updateArchive = "update_archive" }

    public static let appcastURL = URL(string:
        "https://raw.githubusercontent.com/EricAndrechek/Pacer/main/site/public/appcast.xml")!
    public static let priceHistoryURL = URL(string:
        "https://raw.githubusercontent.com/EricAndrechek/Pacer/main/site/public/price-history.json")!

    /// Why a feed could not be read: our own enumerable words, never a description.
    public struct Failure: Error, Sendable, Equatable {
        public let domain: String
        public let code: Int
        public let httpStatus: Int?

        public init(domain: String, code: Int, httpStatus: Int? = nil) {
            self.domain = Self.allowedDomain(domain)
            self.code = code
            self.httpStatus = httpStatus
        }

        /// `http` (a non-200 answer) and `decode` (an answer that did not
        /// parse) are ours; the rest are the two system domains a feed fetch can
        /// fail in. Anything else is `other`, so a stray domain name can't leave.
        static let domains: Set<String> = [NSURLErrorDomain, "http", "decode", "SUSparkleErrorDomain"]
        static func allowedDomain(_ d: String) -> String { domains.contains(d) ? d : "other" }
    }

    // MARK: Appcast failures

    private static let sparkleDomain = "SUSparkleErrorDomain"
    private static let sparkleAppcastParseError = 1000   // SUAppcastParseError
    private static let sparkleDownloadError = 2001       // SUDownloadError

    /// The failure of a finished Sparkle cycle, or nil when the error says
    /// nothing about reaching the feed.
    ///
    /// A failed appcast fetch (DNS, TLS, timeout, HTTP 4xx/5xx) arrives as
    /// `SUDownloadError` (2001) wrapped three times around the `NSURLError`
    /// (`SPUDownloader`, `SPUDownloadDriver`, `SUAppcastDriver`), and a failed
    /// update *archive* download is the same 2001. The code cannot tell them
    /// apart; `feedLoaded` (Sparkle's `didFinishLoadingAppcast` fired in this
    /// cycle) does: a 2001 or parse error (1000) before the appcast loaded is
    /// the feed, one after it is not. "Up to date" (1001) is never a failure.
    /// The failure keeps the innermost error's domain and code.
    public static func appcastFailure(_ error: NSError, feedLoaded: Bool) -> Failure? {
        guard !feedLoaded else { return nil }
        let isFeedError = error.domain == NSURLErrorDomain
            || (error.domain == sparkleDomain
                && (error.code == sparkleDownloadError || error.code == sparkleAppcastParseError))
        guard isFeedError else { return nil }
        var innermost = error
        while let next = innermost.userInfo[NSUnderlyingErrorKey] as? NSError, next !== innermost { innermost = next }
        if innermost.domain == NSURLErrorDomain, innermost.code == NSURLErrorCancelled { return nil }
        let status = innermost.domain == NSURLErrorDomain && innermost.code == NSURLErrorBadServerResponse
            ? (innermost.userInfo["statusCode"] as? Int) : nil
        return Failure(domain: innermost.domain, code: innermost.code, httpStatus: status)
    }

    /// Offline is the Mac's state, not the feed's: counted, never an issue.
    public static func isOffline(_ failure: Failure) -> Bool {
        failure.domain == NSURLErrorDomain
            && (failure.code == NSURLErrorNotConnectedToInternet || failure.code == NSURLErrorDataNotAllowed)
    }

    /// After the primary appcast failed, one more check this soon reads the fallback.
    public static let failoverRecheckDelay: TimeInterval = 15 * 60

    // MARK: Which appcast URL

    /// Primary first, always, unless the check before it failed to reach the
    /// feed: then the next check reads the fallback, and the one after that is
    /// back on the primary whatever the fallback did. Held by the updater
    /// delegate, which Sparkle calls on the main thread only.
    public struct AppcastChooser: Sendable, Equatable {
        enum State: Equatable { case primary, fallback(after: Failure) }
        var state: State = .primary

        public init() {}

        /// What to report when a cycle ends.
        public enum Outcome: Equatable { case none, report(primary: Failure, fallbackOK: Bool) }

        public var usesFallback: Bool { state != .primary }

        /// nil: Sparkle's own `SUFeedURL`. Pure, because Sparkle may ask more than once per check.
        public var feedURLString: String? { usesFallback ? FeedFallback.appcastURL.absoluteString : nil }

        /// A check ended; `failure` is `appcastFailure(...)` of its error, nil if it reached the feed.
        public mutating func finished(failure: Failure?) -> Outcome {
            switch state {
            case .primary:
                if let failure { state = .fallback(after: failure) }
                return .none
            case .fallback(let primary):
                state = .primary
                return .report(primary: primary, fallbackOK: failure == nil)
            }
        }
    }

    // MARK: Reporting

    /// At most one problem per feed per day, kept across launches.
    static func problemKey(_ feed: Feed) -> String { "pacer.feed.problemReported.\(feed.rawValue)" }
    static let problemInterval: TimeInterval = 24 * 3600
    public static let problemMessage = "feed unreachable"
    public static func counterKey(_ feed: Feed) -> String { "feed.fallback_used.\(feed.rawValue)" }
    public static func offlineCounterKey(_ feed: Feed) -> String { "feed.offline.\(feed.rawValue)" }

    public static func problemAttributes(feed: Feed, failure: Failure, fallbackOK: Bool) -> Telemetry.Attributes {
        var out: Telemetry.Attributes = [
            "feed": .string(feed.rawValue),
            "error.domain": .string(failure.domain),
            "error.code": .int(failure.code),
            "fallback": .string(fallbackOK ? "ok" : "failed"),
        ]
        if let status = failure.httpStatus { out["http.status"] = .int(status) }
        return out
    }

    /// Count every fallback use; send the problem at most once a day per feed.
    /// Returns whether a problem was sent. Telemetry decides whether the user
    /// allows it; the limit is spent either way, so toggling it on does not
    /// release a backlog.
    @discardableResult
    public static func report(feed: Feed, failure: Failure, fallbackOK: Bool, now: Date = Date(),
                              store: UserDefaults = PacerPreferences.store,
                              counter: (String) -> Void = { TelemetryCounters.add($0) }) -> Bool {
        if isOffline(failure) {
            counter(offlineCounterKey(feed))
            return false
        }
        counter(counterKey(feed))
        return sendProblem(problemMessage, feed: feed, now: now, store: store,
                           attributes: problemAttributes(feed: feed, failure: failure, fallbackOK: fallbackOK))
    }

    /// The shared once-a-day limit, per feed, kept across launches.
    @discardableResult
    static func sendProblem(_ message: String, feed: Feed, now: Date, store: UserDefaults,
                            attributes: Telemetry.Attributes) -> Bool {
        let key = problemKey(feed)
        if let last = store.object(forKey: key) as? Date,
           now.timeIntervalSince(last) < problemInterval, now >= last { return false }
        store.set(now, forKey: key)
        Telemetry.problem(message, attributes: attributes)
        return true
    }

    // MARK: Update archive download

    public static let downloadProblemMessage = "update download failed"

    /// Domains and codes only: Sparkle's error and the one beneath it.
    public static func downloadProblemAttributes(domain: String, code: Int,
                                                 underlyingDomain: String?, underlyingCode: Int?) -> Telemetry.Attributes {
        var out: Telemetry.Attributes = [
            "feed": .string(Feed.updateArchive.rawValue),
            "error.domain": .string(Failure.allowedDomain(domain)),
            "error.code": .int(code),
        ]
        if let underlyingDomain, let underlyingCode {
            out["error.underlying_domain"] = .string(Failure.allowedDomain(underlyingDomain))
            out["error.underlying_code"] = .int(underlyingCode)
        }
        return out
    }

    @discardableResult
    public static func reportDownloadFailure(domain: String, code: Int, underlyingDomain: String?, underlyingCode: Int?,
                                             now: Date = Date(), store: UserDefaults = PacerPreferences.store) -> Bool {
        sendProblem(downloadProblemMessage, feed: .updateArchive, now: now, store: store,
                    attributes: downloadProblemAttributes(domain: domain, code: code,
                                                          underlyingDomain: underlyingDomain, underlyingCode: underlyingCode))
    }
}
