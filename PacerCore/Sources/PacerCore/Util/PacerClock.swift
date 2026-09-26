import Foundation

/// The current time, as the shared formatters and the widget views read it.
///
/// `Date()`, except in the README screenshot build's widget extension, which
/// pins it to `ScreenshotClock.fixedNow` (#154). The app's own screenshot run
/// does not need this: `bin/fixed-clock.c` pins the whole process's wall clock
/// from outside. The widget extension is launched by the system, which no
/// environment variable reaches, so it is pinned from inside, here.
public enum PacerClock {
    /// Set once, at widget-extension launch, in fixture builds only.
    nonisolated(unsafe) public static var pinned: Date?

    public static var now: Date { pinned ?? Date() }
}

/// The instant and time zone the README screenshots are drawn at (#154).
///
/// Seeded data and every clock label are built from "now", so a run at a
/// different hour drew different pictures: the Now tile read $14.0/hr at one
/// hour and $5.47/hr at another, reset times and chart axes moved, and every
/// ready-for-review produced a commit of noise. Pinned, a PR with no UI
/// change produces no screenshot commit.
///
/// A Friday afternoon: a session running, cycles part-way through, a full
/// morning of hourly history behind the Now tile.
///
/// `bin/dev-screenshots.sh` reads both values from this file, so this is the
/// only copy.
public enum ScreenshotClock {
    /// 2026-09-18 14:30 in `timeZoneID`.
    public static let fixedNowUnix: TimeInterval = 1_789_767_000
    public static let timeZoneID = "America/Los_Angeles"

    public static var fixedNow: Date { Date(timeIntervalSince1970: fixedNowUnix) }

    /// Why the running process is not on the pinned clock, or nil when it is.
    ///
    /// The run advances from the pinned instant in real time (timers need a
    /// moving clock), so "on it" means within the hour a run takes.
    public static func problem(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        if abs(now.timeIntervalSince(fixedNow)) > 3_600 {
            return "the clock is not pinned: it reads \(now), not \(fixedNow)"
                + " (bin/dev-screenshots.sh pins it with bin/fixed-clock.c)"
        }
        if timeZone.identifier != timeZoneID {
            return "the time zone is \(timeZone.identifier), not \(timeZoneID)"
        }
        return nil
    }
}
