import Foundation

/// The link a Sentry event carries to the same Mac's person page in PostHog,
/// so a crash or hang can be read next to that install's usage. Both tools know
/// the Mac by one install id (`AnalyticsIdentity`).
///
/// The id is a random UUID, the same one Sentry already holds for the Mac, so
/// the link discloses nothing new. It must survive `TelemetryScrubber`, whose
/// long-token rule would otherwise eat `com/project/<n>/person/<uuid>`; the
/// scrubber exempts exactly this shape (`TelemetryScrubber.scrub`).
public enum PostHogPersonLink {

    /// Pacer's PostHog project (US cloud).
    public static let projectId = 678727

    /// PostHog's web app, not the ingest host (`PacerPostHogHost`).
    public static let appHost = "https://us.posthog.com"

    public static func url(installId: String, projectId: Int = projectId) -> String {
        "\(appHost)/project/\(projectId)/person/\(installId)"
    }

    /// Exactly the URLs `url(installId:)` makes for a UUID install id.
    static let pattern = try! NSRegularExpression(
        pattern: #"https://us\.posthog\.com/project/[0-9]+/person/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9A-Za-z_-])"#)
}
