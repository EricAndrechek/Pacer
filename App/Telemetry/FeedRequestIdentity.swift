import Foundation
import PacerCore

/// Supplies `X-Pacer-Id` to the two requests Pacer makes to its own site (the
/// Sparkle appcast and the curated price history). Lives here because the id
/// is the PostHog distinct id and the toggle is "Usage data"; PacerCore only
/// sees a header closure. Plan: docs/telemetry-plan.md, "Feed requests".
///
/// Every input is read when a request is built, never at launch, so turning
/// "Usage data" off removes the header from the very next request. No id is
/// created for the purpose: it is sent only once Sentry or PostHog has
/// established it.
enum FeedRequestIdentity {

    static func idHeader() -> [String: String] {
        FeedRequestHeaders.idHeader(
            usageAllowed: { TelemetryController.analyticsAllowed },
            isNormalLaunch: {
                FeedRequestHeaders.mayCarryId(isNormalLaunch: LaunchMode.isNormalLaunch,
                                              environment: ProcessInfo.processInfo.environment)
            },
            installId: {
                AnalyticsIdentity.existingInstallId(in: URL(fileURLWithPath: TelemetryController.cacheDirectory))
            })
    }

    static func installPriceHistoryHeaders() {
        FeedRequestHeaderProvider.priceHistory.setExtra { idHeader() }
    }
}
