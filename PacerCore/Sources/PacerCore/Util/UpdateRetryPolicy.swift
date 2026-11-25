import Foundation

/// When Pacer checks for an update sooner than Sparkle's 6 hours.
public enum UpdateRetryPolicy {

    /// Wait before re-checking after the nth failed update download in a row
    /// (1-based): 30 minutes, then 2 hours, then nil: back to the normal interval.
    public static func downloadRetryDelay(afterFailures n: Int) -> TimeInterval? {
        switch n {
        case 1: return 30 * 60
        case 2: return 2 * 3600
        default: return nil
        }
    }

    /// Two minutes after launch, so a Mac that installed an older held update
    /// finds the newest at once.
    public static let catchUpDelay: TimeInterval = 120

    /// True when Pacer was just updated: a build was recorded at the previous
    /// launch and it differs. A first-ever launch has nothing to catch up.
    public static func needsCatchUpCheck(previousBuild: String?, currentBuild: String) -> Bool {
        guard let previousBuild else { return false }
        return previousBuild != currentBuild
    }

    public static let lastLaunchBuildKey = "pacer.update.lastLaunchBuild"
}
