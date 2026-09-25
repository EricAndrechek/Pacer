import AppKit
import PacerCore

/// Logs every mouse click the app receives in its own windows, with how long
/// after the press it reached the app.
///
/// "I clicked a project and nothing happened" has three different causes that
/// look identical from the chair: the click reached the app late (the main
/// thread was busy), it reached the app on time and no view acted on it, or a
/// view acted and something undid it. `MainThreadStallWatchdog` only answers
/// the first, and only indirectly. This answers it per click, and the
/// `Navigation` / `Modal` lines around it answer the other two.
///
/// Read-only: a local monitor that returns every event unchanged. It observes
/// input the app is already being sent; it never posts, consumes or alters it.
@MainActor
final class ClickLatencyProbe {
    static let shared = ClickLatencyProbe()

    private var monitor: Any?
    private var downAt: TimeInterval?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated {
                ClickLatencyProbe.shared.record(event)
            }
            return event
        }
    }

    private func record(_ event: NSEvent) {
        // The menu-bar popover and status item are their own windows; clicks
        // there are not what this is for, and the status item gets many.
        guard let window = event.window, window.canBecomeMain else { return }
        // `event.timestamp` and `systemUptime` share a clock: time since boot.
        let now = ProcessInfo.processInfo.systemUptime
        let lagMs = Int((now - event.timestamp) * 1000)
        let p = event.locationInWindow
        let at = "(\(Int(p.x)),\(Int(p.y)))"
        switch event.type {
        case .leftMouseDown:
            downAt = event.timestamp
            Log.write("Click", "down \(at) delivered \(lagMs)ms after press")
        case .leftMouseUp:
            let held = downAt.map { " held \(Int((event.timestamp - $0) * 1000))ms" } ?? ""
            downAt = nil
            Log.write("Click", "up \(at) delivered \(lagMs)ms after release\(held)")
        default:
            break
        }
    }
}
