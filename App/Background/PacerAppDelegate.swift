import AppKit
import SwiftUI
import SwiftData
import PacerCore

/// `NSApplicationDelegate` that owns the SwiftData container, the
/// in-process background service (`AppBackgroundService`), and drives
/// Dock-icon visibility based on whether any window is open.
///
/// Why the delegate owns the container instead of `PacerApp.init`:
/// SwiftUI's `@NSApplicationDelegateAdaptor` constructs the delegate
/// during the App's body evaluation, but the exact ordering relative
/// to `App.init` is non-deterministic. Putting both container creation
/// and background-service start under one owner removes the timing
/// concern.
///
/// Lifecycle:
/// - `init()` — open the SwiftData container, register defaults,
///   construct the background service. No I/O or scan starts here;
///   that waits for `applicationDidFinishLaunching`.
/// - `applicationDidFinishLaunching` — start the background service.
///   The service starts whether the user opened the app interactively
///   or it was auto-launched at login (so the LSUIElement-hidden
///   "agent" mode still does data collection).
/// - `applicationShouldTerminate` — block briefly while the service
///   shuts down cleanly, then post a UNUserNotification telling the
///   user collection has stopped.
/// - Window-visibility observers — when a main window becomes visible,
///   switch activation policy to `.regular` so a Dock icon appears.
///   When the last main window closes, switch back to `.accessory` so
///   the app continues to run headless without cluttering the Dock.
///
/// `LSUIElement=true` in `Info.plist` makes the *initial* launch
/// `.accessory`, so a login-at-startup launch shows nothing in the
/// Dock until the user explicitly opens a window.
@MainActor
final class PacerAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// One-shot destination hint set by status-menu actions before
    /// opening the main window. `ContentView.onAppear` consumes (and
    /// clears) this on first mount, so a "Settings…" click from the
    /// status menu lands on the Settings tab even when no window was
    /// previously open. Avoids the synchronous-NotificationCenter-vs-
    /// SwiftUI-mount race that the prior `asyncAfter` workaround was
    /// papering over.
    @MainActor static var pendingDestination: ContentView.Destination?

    let container: ModelContainer
    let backgroundService: AppBackgroundService

    /// Observer lifecycle note: every `NSObjectProtocol` we stash on
    /// this delegate (`windowObservers`, `menuBarPrefObserver`) is added
    /// once in `applicationDidFinishLaunching` / `installMenuBar`. The
    /// delegate itself is process-lived (created by SwiftUI at app
    /// launch, destroyed only when the process exits), so explicit
    /// `removeObserver` would never fire under normal use — process
    /// teardown unregisters every observer automatically.
    /// If this class ever becomes non-process-lived (a test harness
    /// instantiating multiple delegates, a hypothetical "restart in
    /// place" feature), add an `isolated deinit` that calls
    /// `NotificationCenter.default.removeObserver(_:)` on each entry.
    private var windowObservers: [NSObjectProtocol] = []

    // Menu-bar status item state. We own the NSStatusItem directly
    // (rather than using SwiftUI's MenuBarExtra) because MenuBarExtra
    // doesn't expose the NSStatusItem.button needed for right-click
    // context menus. The popover content and label are still SwiftUI
    // — we host them in NSHostingView/NSHostingController.
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    /// Held strong so the SwiftUI content inside the menu keeps its
    /// @Query subscriptions alive between menu opens — without this,
    /// the host would deallocate and SwiftData would re-fetch every
    /// time the user clicked the status item.
    private var statusMenuContentController: NSViewController?
    private var menuBarHostingView: SizingHostingView?
    private var menuBarPrefObserver: NSObjectProtocol?
    // Tracked at class scope so the observer block doesn't capture a
    // local `var` — Swift 6.3 strict-concurrency rejects the local-var
    // form because the @Sendable observer closure makes the capture
    // task-isolated, conflicting with the inner @MainActor Task that
    // mutates it. As an instance property on this @MainActor class it
    // is main-actor isolated, matching the inner Task.
    private var menuBarLastChipsEmpty: Bool = false

    /// One-shot screen hint for the cold-open path. When the user opens
    /// Pacer from the menu bar / hotkey but the window scene was torn
    /// down (closed dashboard → SwiftUI `Window` destroys its NSWindow),
    /// we can't reposition the window synchronously — it doesn't exist
    /// yet. We capture the screen the gesture happened on here and let
    /// the `didBecomeKey` observer reseat the freshly-materialized
    /// window onto it exactly once. Captured at gesture time (not read
    /// in the observer) because the cursor may drift between the click
    /// and the async window creation.
    private var pendingActiveScreen: NSScreen?

    override init() {
        // Screenshot/demo mode: never touch the user's real store, logs,
        // or the single-instance gate (we may be running alongside a live
        // Pacer). Use an in-memory container and let
        // `applicationDidFinishLaunching` drive the capture run instead of
        // the normal scan/menu-bar bring-up.
        if ScreenshotMode.isActive {
            PacerSettings.registerDefaults()
            do {
                container = try PacerStore.makeInMemoryContainer()
            } catch {
                Self.showFatalContainerError(error)
            }
            backgroundService = AppBackgroundService(container: container)
            super.init()
            return
        }

        // Redirect stderr to a log file before anything else so the
        // ScanCoordinator/OAuthPoller log lines (via PacerCore.Log)
        // land somewhere readable. The retired daemon got its
        // stderr→file redirect from launchd's StandardErrorPath plist
        // key; the in-process app has to do the equivalent itself
        // because SMAppService.mainApp launches don't have a way to
        // configure stderr redirection. `make logs` and `make
        // logs-tail` read this same file.
        Self.redirectStderrToLogFile()

        // Single-instance gate. Runs before the SwiftData container
        // opens — a second instance opening the same `pacer.sqlite`
        // would race the existing process's writes. If another Pacer
        // is already running we activate it and exit immediately,
        // skipping container creation and scan-loop bring-up.
        Self.exitIfAnotherInstanceIsRunning()

        // Register defaults before any @AppStorage reads can happen,
        // same reason PacerApp.init used to: `@AppStorage`'s default-
        // value parameter only kicks in when the key is totally
        // absent from the suite, so a first-run user would otherwise
        // see different defaults from a returning user.
        PacerSettings.registerDefaults()
        do {
            container = try PacerStore.makeModelContainer()
        } catch {
            Self.showFatalContainerError(error)
        }
        backgroundService = AppBackgroundService(container: container)
        super.init()
    }

    /// Container open failed — likely a corrupted store or permission
    /// issue. Show the user where to look (logs, the App Group
    /// container) instead of crashing silently into a fatalError.
    /// Returns Never so the compiler knows control doesn't escape.
    private static func showFatalContainerError(_ error: Error) -> Never {
        let alert = NSAlert()
        alert.messageText = "Pacer can't open its data store"
        alert.informativeText = """
        \(error.localizedDescription)

        This usually means the SwiftData store is corrupted or in an unexpected state. \
        Show in Finder to inspect the App Group container; View Logs for the most recent stderr output. \
        After moving or deleting the store, relaunch Pacer to start fresh.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "View Logs")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let url = try? PacerStore.storeURL() {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .alertSecondButtonReturn:
            let logsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Pacer")
            NSWorkspace.shared.open(logsDir)
        default:
            break
        }
        exit(1)
    }

    /// Activate the existing Pacer instance and exit if one is found.
    /// Called from `init()` so the check runs before any SwiftData /
    /// scan-loop work.
    ///
    /// Note: macOS's `open -n` deliberately bypasses Launch Services'
    /// "is it running" gate, which is how multiple instances appeared
    /// in the first place. The runtime check below catches that case
    /// (and also a stray Finder double-click while the app is running
    /// in agent mode without a Dock icon).
    private static func exitIfAnotherInstanceIsRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine }
        guard let other = others.first else { return }
        // Bring the existing one forward so the user gets the same
        // "Pacer popped open" feeling they expected from the second
        // launch — then exit.
        other.activate(options: [.activateAllWindows])
        FileHandle.standardError.write(Data(
            "[Pacer] another instance is running (pid \(other.processIdentifier)); exiting this one\n".utf8
        ))
        exit(0)
    }

    /// Append future stderr writes (including PacerCore.Log output) to
    /// `~/Library/Logs/Pacer/Pacer.err.log`. Best-effort: if directory
    /// creation or freopen fails, stderr stays where it was (typically
    /// /dev/null when launched by Finder/launchd, or the controlling
    /// terminal when launched from `open -a` in a shell). We don't
    /// surface failures because logging is supportive infrastructure
    /// — the app shouldn't fail to launch because of a log redirect
    /// problem.
    ///
    /// Rotation: before opening for append, if the log is over the
    /// rotation threshold (5 MB), rename it to `Pacer.err.log.1`
    /// (overwriting any prior .1) and start fresh. Only one prior
    /// generation is kept — the per-line ScanCoordinator/OAuthPoller
    /// output is voluminous and the previous file already covered
    /// "the previous run", so a single rotation slot is enough for
    /// most debugging without growing the disk forever.
    private static func redirectStderrToLogFile() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pacer", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDir,
            withIntermediateDirectories: true
        )
        let logURL = logsDir.appendingPathComponent("Pacer.err.log")
        rotateIfLarge(at: logURL, threshold: 5 * 1024 * 1024)
        // freopen("...", "a", stderr) replaces the underlying fd of
        // stderr without changing FILE* identity, so existing code
        // writing via `FileHandle.standardError` (PacerCore.Log) and
        // anything that writes to `stderr` directly (system frameworks)
        // both end up in the file.
        _ = logURL.path.withCString { freopen($0, "a", stderr) }
    }

    /// Rename `Pacer.err.log` → `Pacer.err.log.1` when the live log
    /// exceeds the threshold. Best-effort; failures leave the existing
    /// file intact and we just keep appending. The launch-time check
    /// is good enough for a long-running app — the daemon doesn't run
    /// long enough between launches to cross the threshold within a
    /// single session.
    private static func rotateIfLarge(at url: URL, threshold: Int) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > threshold else {
            return
        }
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    /// Disable AppKit's automatic window tabbing globally. Pacer is a
    /// single-window app, so the macOS-default behavior of grouping
    /// "Show Tab Bar" windows into one chrome with multiple tabs (which
    /// the prior `WindowGroup` setup tripped on every Cmd+,) is
    /// unwanted noise.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Screenshot/demo mode: skip scan, menu bar, hotkey, and Dock
        // policy. Seed synthetic data, capture the views off-screen, exit.
        if ScreenshotMode.isActive {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await SampleCostCache.reload()
                ScreenshotMode.seed(into: container)
                await ScreenshotMode.captureAll(container: container)
                exit(0)
            }
            return
        }

        // Clear any "Pacer paused" banner left over from a previous
        // quit. We're alive again, the user is here — the "reopen
        // Pacer" prompt is moot. Also preempts a pending request that
        // the prior process scheduled but couldn't fully deliver
        // before SIGKILL during a dev-cycle quit→relaunch.
        NotificationCoordinator.shared.clearCollectionPausedNotification()
        // If the bundle was just replaced under us (Sparkle auto-update
        // or `make install`), the old widget extension is still running
        // its now-stale binary and chronod won't relaunch it on its own.
        // Bounce it here so widgets pick up the new build's code + data.
        WidgetExtensionRelauncher.bounceIfBundleReplaced()
        backgroundService.start()
        installWindowObservers()
        installMenuBar()
        installGlobalHotkey()
        // Warm the shared sample-cost cache so views (LiveActivity,
        // DayDetail, TodayTimeline) can compute per-sample cost
        // synchronously without each having to async-load its own
        // PricingTable snapshot.
        Task { await SampleCostCache.reload() }
        // Reflect whatever state SwiftUI has put us in by the time
        // we get here — typically zero windows on a login launch,
        // one window on an interactive launch.
        applyActivationPolicyForCurrentWindows()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Run shutdown asynchronously and tell AppKit to wait. Without
        // this the watcher and OAuth poller would be SIGKILLed in
        // place; the cooperative shutdown lets pending SwiftData
        // saves flush. Also fires the "you stopped tracking" banner
        // before exit so a user who quits unintentionally has a
        // visible reminder.
        Task { @MainActor in
            await backgroundService.stop()
            await NotificationCoordinator.shared.notifyCollectionPaused()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// macOS sends this when the user clicks the Dock icon (only
    /// possible if we're in `.regular`) on a running app with no
    /// visible window. Returning true asks AppKit to handle it via
    /// the standard "reopen the app's main window" path; combined
    /// with a SwiftUI `WindowGroup`, the main window reappears.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        true
    }

    /// Don't terminate when the last window closes — the whole point
    /// of the agent shape is that we keep collecting data after the
    /// user dismisses the dashboard. Quit happens via Cmd+Q or the
    /// menu-bar Quit button.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    // MARK: - Activation policy management

    private func installWindowObservers() {
        let center = NotificationCenter.default
        let didBecomeKey = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract the window pointer outside the @MainActor Task —
            // capturing the whole `note` would carry a non-Sendable
            // userInfo dict across the boundary, which Swift 6
            // diagnoses as a data-race risk.
            let window = note.object as? NSWindow
            Task { @MainActor in
                guard let self else { return }
                self.applyActivationPolicyForCurrentWindows()
                if let window {
                    Self.ensureWindowAutosaves(window)
                    Self.ensureWindowOnScreen(window)
                    // Cold-open reseat: a window we asked AppKit to
                    // materialize (closed dashboard → reopened from the
                    // menu bar) just became key. Move it onto the screen
                    // the user opened us from, then clear the one-shot
                    // hint so ordinary refocus events never relocate it.
                    if let screen = self.pendingActiveScreen {
                        self.pendingActiveScreen = nil
                        Self.reposition(window, onto: screen)
                    }
                }
            }
        }
        let willClose = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // willClose fires before the window leaves NSApp.windows,
            // so dispatching on the main queue lets the count reflect
            // post-close state.
            Task { @MainActor in
                self?.applyActivationPolicyForCurrentWindows()
            }
        }
        windowObservers = [didBecomeKey, willClose]
    }

    /// Fallback AppKit autosave name we install when SwiftUI didn't
    /// already give the main window one. Most builds will use whatever
    /// `Window("Pacer", id: "main")` produces; this is just the safety
    /// net for the dev-build case where SwiftUI sometimes leaves the
    /// property empty.
    private static let mainWindowAutosaveName = "PacerMainWindow"

    /// SwiftUI's `Window` scene typically auto-sets a non-empty
    /// `frameAutosaveName` from the scene id — but the exact behavior
    /// has shifted across macOS releases and at least one Sequoia
    /// point release left it empty in dev builds. Install a fallback
    /// name when that happens so frame size + position reliably
    /// persist across launches.
    ///
    /// Also pins the menu-bar-app collection behavior. Both `Window`
    /// scene's `.defaultPosition(.center)` and `.defaultSize(...)`
    /// modifiers handle first-launch placement on the SwiftUI side,
    /// so this function doesn't touch the frame.
    private static func ensureWindowAutosaves(_ window: NSWindow) {
        guard window.canBecomeMain, !(window is NSPanel) else { return }
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName(mainWindowAutosaveName)
        }
        applyMenuBarAppBehavior(window)
    }

    /// Make the main window behave like a tool window for a menu-bar
    /// agent app: when the user activates Pacer (clicks the status
    /// item, hits the global shortcut, ⌘-Tabs to it), the window
    /// follows them to the active Space rather than yanking them via
    /// Mission Control to whichever Space it was last left on.
    ///
    /// `.moveToActiveSpace` is exactly the right knob for this — it
    /// only fires on app activation, doesn't make the window appear
    /// on every Space at once, and doesn't fight Spaces assignment
    /// for users who pin windows to specific Spaces. It matches what
    /// 1Password / Things / Raycast / Bartender / etc. all do.
    ///
    /// We `.insert` rather than assign so we preserve whatever defaults
    /// AppKit/SwiftUI already set (most importantly `.managed`, which
    /// is what lets the window participate in Mission Control / Stage
    /// Manager normally).
    private static func applyMenuBarAppBehavior(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    /// macOS persists the main window's frame across launches via the
    /// `frameAutosaveName`. If the user moved the window onto a
    /// secondary display and then disconnected it, the restored frame
    /// can sit entirely off-screen — the user opens "Pacer" from the
    /// menu bar, sees nothing, and has no obvious way back. Recenter
    /// on the primary screen (the one with the menu bar) and save so
    /// the next launch doesn't repeat the dance.
    ///
    /// `NSWindow.center()` is AppKit's blessed centering API; on
    /// post-display-disconnect setups it lands on whatever screen
    /// macOS has elected as primary, which is exactly where the user
    /// is working from after their secondary went away.
    private static func ensureWindowOnScreen(_ window: NSWindow) {
        // Skip auxiliary windows (panels, menu-bar popover host) — only
        // the main "Pacer" window needs reseating.
        guard window.canBecomeMain, !(window is NSPanel) else { return }
        let onSomeScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(window.frame)
        }
        guard !onSomeScreen else { return }
        window.center()
        window.saveFrame(usingName: window.frameAutosaveName)
    }

    /// The screen the user is currently working on — the one whose menu
    /// bar they just clicked, or where the cursor sits when the global
    /// hotkey fires. `NSEvent.mouseLocation` and `NSScreen.frame` share
    /// the same bottom-left-origin global coordinate space, so a simple
    /// containment test resolves it. Falls back to `NSScreen.main` (the
    /// screen with the key window / active menu bar) when the cursor is
    /// in a gap between displays.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Move the main window onto `target` when — and only when — it's
    /// currently on a *different* display. A user who keeps Pacer on one
    /// screen and positions it deliberately is never disturbed; a
    /// multi-monitor user gets the window to follow them to whichever
    /// display they opened it from. We preserve the window's relative
    /// position within the screen (top-left stays top-left, etc.) rather
    /// than always centering, so the layout stays familiar across the
    /// jump, then clamp so the whole frame lands inside the visible area.
    private static func reposition(_ window: NSWindow, onto target: NSScreen) {
        guard window.canBecomeMain, !(window is NSPanel) else { return }
        let frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        // Already on the target display? Leave the in-screen position
        // exactly as the user left it — we only ever relocate across
        // displays, never nudge within one.
        if target.frame.contains(center) { return }

        let targetVF = target.visibleFrame
        let source = NSScreen.screens.first { $0.frame.contains(center) }
        var origin: NSPoint
        if let sourceVF = source?.visibleFrame, sourceVF.width > 0, sourceVF.height > 0 {
            let relX = (frame.minX - sourceVF.minX) / sourceVF.width
            let relY = (frame.minY - sourceVF.minY) / sourceVF.height
            origin = NSPoint(x: targetVF.minX + relX * targetVF.width,
                             y: targetVF.minY + relY * targetVF.height)
        } else {
            // Window wasn't on any screen (e.g. a stale off-screen
            // autosaved frame) — center it on the target instead.
            origin = NSPoint(x: targetVF.midX - frame.width / 2,
                             y: targetVF.midY - frame.height / 2)
        }
        // Clamp fully on-screen. `max(targetVF.minX, maxX)` keeps the
        // lower bound sane when the window is wider/taller than the
        // target's visible area (pins to top-left instead of inverting).
        let maxX = targetVF.maxX - frame.width
        let maxY = targetVF.maxY - frame.height
        origin.x = min(max(origin.x, targetVF.minX), max(targetVF.minX, maxX))
        origin.y = min(max(origin.y, targetVF.minY), max(targetVF.minY, maxY))
        window.setFrameOrigin(origin)
    }

    /// `.regular` when at least one user-visible window is open
    /// (Dock icon shows so user can Cmd+Q, Cmd+Tab back, etc.);
    /// `.accessory` otherwise (Dock icon hides, app keeps running
    /// in the background). Filters out NSPanel and the menu-bar
    /// extra's hosting window so they don't keep the Dock icon
    /// alive.
    func applyActivationPolicyForCurrentWindows() {
        let visibleMainWindows = NSApp.windows.filter { window in
            guard window.isVisible else { return false }
            // Exclude utility/system windows. NSPanel covers most
            // (Settings is hosted in one). The menu-bar extra's
            // window is also non-main and shouldn't keep the Dock
            // icon alive.
            if window is NSPanel { return false }
            if !window.canBecomeMain { return false }
            return true
        }
        let hasVisibleMain = !visibleMainWindows.isEmpty
        let target: NSApplication.ActivationPolicy =
            hasVisibleMain ? .regular : .accessory
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
        // Publish to the shared visibility monitor too. ScanCoordinator
        // widens its watcher cadence when hidden, and `FreshnessPulse`
        // stops its TimelineView — both keep the always-running app
        // from burning CPU on UI nobody can see.
        PacerWindowVisibility.shared.setMainWindowVisible(hasVisibleMain)
    }

    // MARK: - Menu bar (custom NSStatusItem)

    /// Bring up the status item if the user has any chips configured.
    /// Subscribes to App Group `UserDefaults` changes so toggling every
    /// chip off (or back on) adds/removes the icon without a relaunch.
    /// Per-chip reordering and content changes are handled reactively
    /// inside `MenuBarLabel` via `@AppStorage` — no rebuild needed.
    private func installMenuBar() {
        rebuildMenuBarForCurrentChips()
        // Only rebuild when the "is the item present at all" answer
        // changes (empty chip list ↔ at least one chip). Every other
        // chip-list change is handled by the SwiftUI label re-render.
        menuBarLastChipsEmpty = currentChipsAreEmpty()
        menuBarPrefObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: PacerSettings.store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let nowEmpty = self.currentChipsAreEmpty()
                if nowEmpty != self.menuBarLastChipsEmpty {
                    self.menuBarLastChipsEmpty = nowEmpty
                    self.rebuildMenuBarForCurrentChips()
                }
            }
        }
    }

    /// True when the user has zero chips configured — the status item
    /// should be torn down. `string(forKey:)` returns the registered
    /// default ("icon,five_hour_pct") for a never-set key, so a fresh
    /// install shows the item by default.
    private func currentChipsAreEmpty() -> Bool {
        let raw = PacerSettings.store.string(forKey: PacerSettings.Key.menuBarChips) ?? ""
        return raw.split(separator: ",").isEmpty
    }

    private func rebuildMenuBarForCurrentChips() {
        if currentChipsAreEmpty() {
            teardownMenuBar()
        } else if statusItem == nil {
            buildStatusItem()
        }
    }

    private func buildStatusItem() {
        // Start with a placeholder width; the host's fittingSize feeds
        // back into NSStatusItem.length once the SwiftUI body has had a
        // chance to lay out. `variableLength` alone *doesn't* size off a
        // custom subview — it measures the button's native image+title,
        // which we never set — so without an explicit length the button
        // collapses to the system-default ~38pt and clips any chips
        // beyond a single icon.
        let item = NSStatusBar.system.statusItem(withLength: 30)
        guard let button = item.button else {
            return
        }

        // Host MenuBarLabel as a SwiftUI view inside the button. We
        // get @Query reactivity, the pulse animation, and tooltip for
        // free. The host is a `SizingHostingView` — a tiny subclass
        // that reports SwiftUI body size changes back via a closure
        // so we can resize the NSStatusItem to fit.
        let host = SizingHostingView(
            rootView: AnyView(
                DayKeyedContent {
                    MenuBarLabel()
                        .modelContainer(self.container)
                }
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        // Pin host on all four edges so it tracks button bounds — and
        // separately drive the button (via `item.length`) off the
        // host's fittingSize. The two coordinate through the resize
        // callback below, not through AutoLayout.
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        // Match `item.length` to the SwiftUI content width whenever the
        // hosted body re-lays out (chip-list change, percent text grow,
        // active-model name change). Without this the button stays at
        // its initial length and the second/third/fourth chip clip off
        // the right edge invisibly.
        host.onContentSizeChange = { [weak item] size in
            // Guard against weird zero sizes during early layout; AppKit
            // throws assertion failures when length goes negative.
            let width = max(20, ceil(size.width))
            item?.length = width
        }
        menuBarHostingView = host

        // Attach an NSMenu (not an NSPopover). NSStatusItem handles
        // the click → open and click-elsewhere → close flow itself,
        // gives the button a native "selected" highlight while the
        // menu is open, and participates in menu-bar handoff (clicking
        // another menu-bar item closes ours and opens that one in one
        // motion). The popover variant we used to have did none of
        // these without manual button-highlight management and was a
        // tracking discontinuity vs the rest of the menu bar.
        let menu = buildStatusMenu()
        item.menu = menu

        statusItem = item
        statusMenu = menu
    }

    private func teardownMenuBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        menuBarHostingView = nil
        statusMenu = nil
        statusMenuContentController = nil
    }

    /// Build the dropdown menu attached to the status item via
    /// `item.menu`. One custom-view item up top with the SwiftUI pace
    /// + today content, then native NSMenuItems for the standard
    /// actions (Open / Settings / Quit). The action items get real
    /// keyboard shortcuts and the macOS-default menu chrome — the
    /// previous popover footer was a row of SwiftUI buttons that
    /// looked like custom UI in the middle of an otherwise-native
    /// menu-bar interaction.
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        // Re-measure the custom content view's height each time the menu opens
        // (see `menuWillOpen`) so dynamically-discovered scoped rows never clip.
        menu.delegate = self
        // Don't validate menu items via responder chain — we hard-wire
        // their `target` so they're always enabled. Without this the
        // pace/today custom-view item disables itself (no action) and
        // looks dim.
        menu.autoenablesItems = false

        // Custom-view item: pace rows + today's totals. NSHostingController
        // is retained on the delegate so SwiftData @Query subscriptions
        // stay live between opens. The view re-evaluates its body in
        // response to data changes regardless of whether the menu is
        // visible — so when the user opens the menu, the numbers are
        // already current.
        let contentController = NSHostingController(
            rootView: AnyView(
                DayKeyedContent {
                    MenuStatusContent()
                        .modelContainer(self.container)
                        .environment(\.usageEngine, self.backgroundService.engine)
                }
            )
        )
        // NSMenuItem.view doesn't auto-size — the menu reads the
        // view's frame at attach time. Use the host's fittingSize so
        // the SwiftUI body's intrinsic dimensions drive the layout.
        let fittingSize = contentController.view.fittingSize
        contentController.view.frame = NSRect(
            x: 0, y: 0,
            width: max(280, fittingSize.width),
            height: max(120, fittingSize.height)
        )
        let contentItem = NSMenuItem()
        contentItem.view = contentController.view
        // We don't want this item to highlight on hover — it's
        // informational, not actionable. Leaving `target`/`action`
        // nil makes NSMenu skip it during keyboard navigation as
        // well, which is the right semantics.
        menu.addItem(contentItem)
        statusMenuContentController = contentController

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(
            title: "Open Pacer",
            action: #selector(menuOpenMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(menuOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Pacer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        return menu
    }

    /// NSMenuDelegate — just before the status menu drops, re-measure the
    /// SwiftUI content item's height. `NSMenuItem.view` is sized once at attach
    /// time (`buildStatusMenu`), so a scoped per-model window discovered *after*
    /// the menu was built would otherwise render into a too-short frame and clip
    /// its lower rows. Re-reading `fittingSize` here — after SwiftUI has laid the
    /// current window set out (its @Query stays live while the menu is closed) —
    /// keeps the drop-down tall enough for however many windows are in play.
    func menuWillOpen(_ menu: NSMenu) {
        guard let view = statusMenuContentController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        let width = max(280, fitting.width)
        let height = max(120, fitting.height)
        if abs(view.frame.width - width) > 0.5 || abs(view.frame.height - height) > 0.5 {
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
    }

    /// Ensure the main `Window("Pacer", id: "main")` scene is on
    /// screen and frontmost. Returns `true` if a main window already
    /// existed (and was just brought forward); `false` if the call
    /// had to ask AppKit to materialize it via the reopen flow.
    ///
    /// Callers that want to additionally signal a destination
    /// (status menu's "Settings…") branch on the return value:
    /// when true, post the destination notification directly because
    /// `ContentView` is already subscribed; when false, stash the
    /// destination on `pendingDestination` so the freshly-mounting
    /// `ContentView.onAppear` consumes it.
    @discardableResult
    private func ensureMainWindowVisible() -> Bool {
        // `NSApp.activate(ignoringOtherApps:)` was effectively neutered
        // in macOS 14 — third-party apps can no longer pull focus
        // from the foreground app unless the activation was triggered
        // by an explicit user gesture (status-item click, registered
        // global shortcut). The no-arg form is the one Apple says to
        // use now; it respects the "yielded focus" rules and reliably
        // brings us forward when called from one of those gestures.
        // The deprecated form would silently leave the window behind
        // whatever app was previously frontmost.
        // Resolve the display the user opened us from BEFORE anything
        // async runs — the cursor may drift afterward.
        let target = Self.activeScreen()
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            // Pin the menu-bar-app collection behavior BEFORE
            // `makeKeyAndOrderFront` so the very first activation
            // already pulls the window to the current Space rather
            // than bouncing the user via Mission Control to wherever
            // the window was last left.
            Self.applyMenuBarAppBehavior(window)
            // Follow the user to the screen they opened us from (no-op
            // if it's already there). Done before ordering front so
            // there's no visible jump across displays.
            if let target { Self.reposition(window, onto: target) }
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return true
        }
        // Cold open: the window doesn't exist yet and will materialize
        // asynchronously via the reopen flow below. Stash the target
        // screen so `didBecomeKey` reseats the new window onto it once.
        pendingActiveScreen = target
        // No window exists. With `LSUIElement=true` and a SwiftUI
        // `Window("Pacer", id: "main")` scene, closing the dashboard
        // tears the window down — the scene is still in memory but no
        // visible NSWindow. Re-opening our own bundle URL triggers
        // AppKit's "this app is already running → call
        // `applicationShouldHandleReopen`" flow, which causes the
        // SwiftUI Window scene to materialize its singleton window
        // again. There's no other AppDelegate-accessible API for this
        // — `openWindow(id:)` only works from inside a SwiftUI view.
        NSWorkspace.shared.open(Bundle.main.bundleURL)
        return false
    }

    @objc private func menuOpenMainWindow() {
        ensureMainWindowVisible()
    }

    /// Register the global hotkey (⌥⌘P by default) and observe its
    /// press notification. Called once from
    /// `applicationDidFinishLaunching`. Registration is best-effort —
    /// a chord collision with another app leaves Pacer reachable via
    /// the menu bar / Dock but skips the hotkey.
    private func installGlobalHotkey() {
        HotkeyManager.shared.registerDefaultHotkey()
        NotificationCenter.default.addObserver(
            forName: .pacerHotkeyToggleWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggleMainWindow()
            }
        }
    }

    /// Hotkey behavior: if the main window is already key + frontmost,
    /// hide it. Otherwise bring it forward. Matches the user
    /// expectation for menu-bar app shortcuts (1Password, Raycast,
    /// Bartender all do this).
    private func toggleMainWindow() {
        let mainWindow = NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
        if let window = mainWindow,
           window.isKeyWindow,
           window.isVisible,
           NSApp.isActive {
            window.orderOut(nil)
            // Closing the last window flips us back to .accessory
            // via the willCloseNotification observer; nothing else
            // to do here.
            return
        }
        ensureMainWindowVisible()
    }

    @objc private func menuOpenSettings() {
        let wasAlreadyOpen = ensureMainWindowVisible()
        if wasAlreadyOpen {
            // ContentView is already mounted and subscribed via
            // `.onReceive(...pacerOpenSettings)`. Post-and-go.
            NotificationCenter.default.post(name: .pacerOpenSettings, object: nil)
        } else {
            // ContentView is about to mount. Stash the destination
            // so its `.onAppear` lands us on Settings instead of the
            // default Dashboard. Deterministic; no timer required.
            Self.pendingDestination = .settings
        }
    }
}

/// `NSHostingView<AnyView>` subclass that calls a closure when its
/// intrinsic content size changes. Used by the status-item host so
/// `NSStatusItem.length` can track the SwiftUI body's natural width
/// — `variableLength` alone only measures `button.image` + `title`,
/// neither of which we set, so without a manual length the button
/// collapses to a system default and clips chips off the right.
///
/// `intrinsicContentSize` is overridden to fire the callback whenever
/// AppKit asks AutoLayout to re-measure us. That covers the bulk of
/// real changes: chip-list edits, percent text growing from "6%" to
/// "100%", active-model name updates. A few SwiftUI redraws that
/// don't change layout will trigger spurious callbacks too, but
/// `NSStatusItem.length = x` is idempotent, so the over-fire is
/// harmless.
final class SizingHostingView: NSHostingView<AnyView> {
    var onContentSizeChange: ((NSSize) -> Void)?

    private var lastReportedSize: NSSize = .zero

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        // SwiftUI sometimes returns `noIntrinsicMetric` (-1) during
        // early layout; skip those — there's nothing useful to size to.
        guard size.width > 0 else { return size }
        if abs(size.width - lastReportedSize.width) > 0.5
            || abs(size.height - lastReportedSize.height) > 0.5 {
            lastReportedSize = size
            // Defer the callback so we don't reenter layout while
            // `intrinsicContentSize` is being computed; AppKit warns
            // loudly when constraints change mid-layout pass.
            let report = onContentSizeChange
            DispatchQueue.main.async { report?(size) }
        }
        return size
    }
}
