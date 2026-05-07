import Foundation
import SwiftData

/// One observation of Claude Code's rate-limit window state. Two windows
/// are tracked: the 5-hour rolling block and the 7-day rolling block.
/// Source labels which probe wrote the row — `statusline` for sub-second
/// `pacertap` pushes during active sessions, `oauth` for the 5-minute
/// background poll of `/api/oauth/usage`. We keep the history rather
/// than overwriting so the dashboard can show the curve and we can spot
/// data divergence between sources.
@Model
public final class RateLimitSample {
    public var sampledAt: Date
    /// `"five_hour"` or `"seven_day"`. String rather than enum so old
    /// rows don't fail to decode if we add a new window kind later
    /// (Anthropic could add e.g. a 1h or 30d window).
    public var window: String
    /// Percentage of the window consumed, 0–100. Server returns this
    /// pre-computed; we don't divide here.
    public var usedPercentage: Double
    public var resetsAt: Date
    /// `"statusline"` or `"oauth"`. Lets the read path prefer one source
    /// over the other when both are fresh, and lets us debug-compare.
    public var source: String

    public init(
        sampledAt: Date,
        window: String,
        usedPercentage: Double,
        resetsAt: Date,
        source: String
    ) {
        self.sampledAt = sampledAt
        self.window = window
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.source = source
    }
}
