import AppKit
import SwiftUI
import SwiftData
import PacerCore

/// The one check in this project that cannot be done off-screen, packaged so it
/// costs the person at the keyboard four seconds and nothing else.
///
/// **Why it exists.** `NSMenu` runs its own event-tracking loop. Nothing outside
/// a real menu session reproduces it — not `NSHostingView` in an off-screen
/// window, not a unit test, not the live renderer. So "does a tooltip appear
/// when you hover a row of the menu-bar popover" has exactly one answer path: a
/// real menu, on a real screen, with a real cursor over it.
///
/// **What that obliges.** Read "Never take over the machine" in `AGENTS.md`
/// first. Taking the cursor is allowed only with the owner's go-ahead for *that
/// run*, and only when the run is already built, deterministic and quick. This
/// type is the "already built" half:
///
/// - **It computes its own target.** The row's screen rect comes from the view
///   hierarchy the menu actually built, so there are no coordinates to guess
///   and nothing to re-try. A script measuring from outside would be a
///   trial-and-error loop on someone's desktop.
/// - **It is its own process, with its own data.** A separate status item over
///   an in-memory fixture, so the running Pacer is untouched, the store is not
///   contended, and the row values are known in advance — which is what makes
///   the resulting PNG assertable rather than merely viewable.
/// - **It puts the cursor back.** Position is captured before anything moves
///   and restored on every exit path, including failure.
/// - **It ends.** Menu cancelled, status item removed, process exits non-zero
///   on any failure so the wrapper script can say so without a human reading
///   the output.
///
/// Gated on `PACER_TOOLTIP_SELFTEST=1`. Nothing observes for it and no code path
/// reaches it without that variable in this process's environment, so it cannot
/// be triggered remotely or by accident.
@MainActor
enum MenuBarTooltipSelfTest {

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["PACER_TOOLTIP_SELFTEST"] == "1"
    }

    /// Where the PNG lands. `PACER_TOOLTIP_SELFTEST_DIR` or the working
    /// directory.
    static var outputDirectory: URL {
        let raw = ProcessInfo.processInfo.environment["PACER_TOOLTIP_SELFTEST_DIR"]
        return URL(fileURLWithPath: raw ?? FileManager.default.currentDirectoryPath)
    }

    /// macOS waits before showing a tooltip, and the wait is a user default
    /// (`NSInitialToolTipDelay`, milliseconds) rather than a constant. Read it,
    /// fall back to AppKit's own default, and add a margin — waiting a beat
    /// longer costs nothing, sampling too early is a false negative that would
    /// cost a second run and a second go-ahead.
    static var tooltipDelay: TimeInterval {
        let ms = UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay")
        let base = ms > 0 ? Double(ms) / 1000.0 : 1.5
        return base + 1.0
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[Pacer tooltip-selftest] \(message)\n".utf8))
    }

    /// Run the whole check and exit. Never returns.
    ///
    /// **Everything after the menu opens is timer-driven, and it has to be.**
    /// `performClick` enters `NSMenu`'s own modal tracking loop, which blocks
    /// the main thread until the menu closes — so `await`, `DispatchQueue.main`
    /// and every other main-actor continuation are frozen for exactly the
    /// window this test needs to act in. A `Timer` registered in `.common` mode
    /// does fire during tracking (the same reason `MainThreadStallWatchdog`
    /// uses that mode), so the hover, the wait and the capture run from a
    /// state machine that was fully scheduled *before* the click.
    ///
    /// That also makes the run deterministic: every step has an absolute
    /// deadline set up front, and the last one cancels tracking, which is what
    /// unblocks the code below and lets the process exit.
    static func run(container: ModelContainer) async -> Never {
        // Captured first, restored on every exit path.
        let cursorHome = NSEvent.mouseLocation

        NSApp.setActivationPolicy(.accessory)

        guard let item = makeStatusItem(container: container), let button = item.button else {
            log("could not create the status item")
            restoreCursor(to: cursorHome)
            exit(2)
        }

        // Safe to await here — the menu is not open yet, so the run loop is
        // ours. The status item's length is driven by its SwiftUI body's
        // fitting size, and clicking before that settles can miss the button.
        try? await Task.sleep(for: .milliseconds(900))

        let out = outputDirectory.appendingPathComponent("menubar-tooltip.png")
        let plan = Plan(item: item, output: out)
        schedule(plan)

        // Blocks until `cancelTracking`, which the plan's last step performs.
        button.performClick(nil)

        NSStatusBar.system.removeStatusItem(item)
        restoreCursor(to: cursorHome)

        guard plan.foundRow else {
            log("the menu's hosted content was not on screen — nothing was hovered")
            exit(3)
        }
        guard plan.captured else {
            log("screen capture failed")
            exit(4)
        }
        log("wrote \(out.path)")
        log("hovered \(Int(plan.hoverPoint.x)),\(Int(plan.hoverPoint.y)) — "
            + "the tooltip, if any, is beside that point")
        exit(0)
    }

    /// Mutable state the timer steps share. A class because the timer closure
    /// needs to write back what happened for the caller to report.
    private final class Plan {
        let item: NSStatusItem
        let output: URL
        var foundRow = false
        var captured = false
        var hoverPoint: CGPoint = .zero
        var step = 0
        init(item: NSStatusItem, output: URL) {
            self.item = item
            self.output = output
        }
    }

    /// The state machine. One repeating timer, absolute deadlines, no
    /// conditionals that depend on what the screen looks like.
    private static func schedule(_ plan: Plan) {
        let t0 = Date()
        // Hover early, then hold still for the tooltip delay. The nudge is a
        // second move a beat after the first: a warp repositions the cursor
        // without generating the mouse-moved event tracking waits for.
        let hoverAt = t0.addingTimeInterval(0.45)
        let nudgeAt = hoverAt.addingTimeInterval(0.15)
        let captureAt = nudgeAt.addingTimeInterval(tooltipDelay)
        let doneAt = captureAt.addingTimeInterval(0.35)

        // The timer is held here rather than taken as the closure's argument:
        // passing the `Timer` into a `@MainActor` closure is a Sendable
        // violation under strict concurrency, and it is main-thread-only state
        // either way.
        var ticker: Timer?
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                if plan.step == 0, now >= hoverAt {
                    plan.step = 1
                    guard let rect = hostedRowRect() else {
                        // Nothing to hover — stop rather than flail. The caller
                        // reports it and exits non-zero.
                        plan.step = 4
                        ticker?.invalidate()
                        plan.item.menu?.cancelTracking()
                        return
                    }
                    plan.foundRow = true
                    plan.hoverPoint = CGPoint(x: rect.midX, y: rect.midY)
                    moveCursor(to: plan.hoverPoint)
                } else if plan.step == 1, now >= nudgeAt {
                    plan.step = 2
                    moveCursor(to: CGPoint(x: plan.hoverPoint.x + 1, y: plan.hoverPoint.y))
                } else if plan.step == 2, now >= captureAt {
                    plan.step = 3
                    plan.captured = capture(to: plan.output)
                } else if plan.step == 3, now >= doneAt {
                    plan.step = 4
                    ticker?.invalidate()
                    plan.item.menu?.cancelTracking()
                }
            }
        }
        // `.common` covers `.eventTracking`, which is the mode NSMenu runs its
        // tracking loop in. Without it none of the above fires until the menu
        // closes, by which time there is nothing left to photograph.
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Pieces

    /// The same status item the real app builds, over the passed container.
    private static func makeStatusItem(container: ModelContainer) -> NSStatusItem? {
        let item = NSStatusBar.system.statusItem(withLength: 30)
        guard let button = item.button else { return nil }

        let host = NSHostingView(
            rootView: AnyView(MenuBarLabel().modelContainer(container))
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

        let menu = NSMenu()
        menu.autoenablesItems = false
        let controller = NSHostingController(
            rootView: AnyView(MenuStatusContent().modelContainer(container))
        )
        let fitting = controller.view.fittingSize
        controller.view.frame = NSRect(
            x: 0, y: 0,
            width: max(280, fitting.width),
            height: max(120, fitting.height))
        let contentItem = NSMenuItem()
        contentItem.view = controller.view
        menu.addItem(contentItem)
        item.menu = menu

        selfTestContent = controller
        selfTestLabel = host
        return item
    }

    /// Retained for the same reason as `selfTestContent`.
    private static var selfTestLabel: NSView?

    /// Retained for the life of the run — an `NSHostingController` released
    /// early takes its view (and the menu's content) with it.
    private static var selfTestContent: NSHostingController<AnyView>?

    /// Screen rect of the row to hover.
    ///
    /// Found through the live view hierarchy rather than by arithmetic on the
    /// menu's frame: the content view is the one attached to the menu item, so
    /// its window and its own bounds give the answer the menu actually laid
    /// out. Targets the lower portion, where `todayValueRow` puts the values
    /// whose exact figures the tooltip exists to show.
    private static func hostedRowRect() -> CGRect? {
        guard let view = selfTestContent?.view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        guard onScreen.width > 1, onScreen.height > 1 else { return nil }
        // Bottom sixth, horizontally right-of-centre: the value column.
        return CGRect(
            x: onScreen.minX + onScreen.width * 0.70,
            y: onScreen.minY + onScreen.height * 0.06,
            width: onScreen.width * 0.20,
            height: onScreen.height * 0.10)
    }

    /// Warp plus a synthetic move. The warp alone repositions the cursor
    /// without telling anything that it moved, which is exactly the event the
    /// tooltip timer waits for.
    ///
    /// Both take Quartz global coordinates (origin top-left), while
    /// `NSEvent.mouseLocation` and window frames are Cocoa (origin
    /// bottom-left). Flipping in one place keeps every caller in Cocoa.
    private static func moveCursor(to cocoaPoint: CGPoint) {
        let flipped = flipToQuartz(cocoaPoint)
        CGWarpMouseCursorPosition(flipped)
        CGAssociateMouseAndMouseCursorPosition(1)
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: flipped, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
    }

    private static func restoreCursor(to cocoaPoint: CGPoint) {
        CGWarpMouseCursorPosition(flipToQuartz(cocoaPoint))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private static func flipToQuartz(_ point: CGPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    /// Full-screen grab. The tooltip is its own window and may sit outside the
    /// menu's bounds, so cropping to the menu risks cutting off the very thing
    /// being looked for.
    private static func capture(to url: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x silent, -o no window shadow.
        task.arguments = ["-x", "-o", url.path]
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
            && FileManager.default.fileExists(atPath: url.path)
    }

}
