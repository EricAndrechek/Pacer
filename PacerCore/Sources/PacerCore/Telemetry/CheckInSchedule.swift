import Foundation

/// When the daily check-in (`DailyCheckIn.runIfDue`) is due: once per local
/// day, and again when the app's release changed since the last one.
///
/// **Why the release too**: a Mac that checked in on the old version keeps
/// quiet on the new one until the next day, so a release looked unadopted for
/// a day. On 2026-11-05 a Mac checked in on 0.8.1 and, 48 seconds later, ran
/// 0.8.2 for the rest of the day without a check-in to either Sentry or
/// PostHog.
public enum CheckInSchedule {

    public enum Reason: String, Sendable, Equatable {
        /// The first check-in of a local day.
        case day
        /// The day was reported already, by another release.
        case version
    }

    /// The defaults keys `DailyCheckIn` stores beside each other, before the
    /// work, so a check-in is never started twice.
    public static let lastDayKey = "pacer.telemetry.checkin.lastDay"
    public static let lastReleaseKey = "pacer.telemetry.checkin.lastRelease"

    /// - Parameters:
    ///   - release: the Sentry release name. Debug builds all report one
    ///     (`…@dev`), so reinstalling a Debug build does not check in again.
    /// - Returns: nil when nothing is due. A store from before the release
    ///   key existed (nil `lastRelease`) is due as `.version` on a day it has
    ///   already checked in: that is the first launch of a newer version.
    public static func due(lastDay: String?, lastRelease: String?,
                           today: String, release: String) -> Reason? {
        if lastDay != today { return .day }
        if lastRelease != release { return .version }
        return nil
    }
}
