import AppKit
import PacerCore

// Stand-ins for the app-target symbols App/Update names, so those files
// compile verbatim into the end-to-end test app. Each is what Pacer's own
// answers to on a Mac with no dashboard open and no diagnostic mode: the test
// is about the update path, and none of these is on it.

/// Pacer's dashboard window bookkeeping. The test app has no windows.
enum MainWindowPlacement {
    static func isDashboard(_ window: NSWindow) -> Bool { false }
    static var wasOpen: Bool { false }
}

/// The crash relauncher (#412). Not started here: nothing relaunches the test
/// app but Sparkle.
enum CrashRelauncher {
    static func standDown() {}
}

/// The `X-Pacer-Id` header. The local feed has no use for one.
enum FeedRequestIdentity {
    static func idHeader() -> [String: String] { [:] }
}

/// Pacer's README-screenshot run. Never this app.
enum ScreenshotMode {
    static var isActive: Bool { false }
    static let pinnedVersion = AppVersionLabel(kind: .release("0.0.0"))
}

/// Pacer's off-screen render run. Never this app.
enum LiveRenderMode {
    static var isActive: Bool { false }
}
