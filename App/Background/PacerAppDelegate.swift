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
final class PacerAppDelegate: NSObject, NSApplicationDelegate {

    let container: ModelContainer
    let backgroundService: AppBackgroundService

    private var windowObservers: [NSObjectProtocol] = []

    // Menu-bar status item state. We own the NSStatusItem directly
    // (rather than using SwiftUI's MenuBarExtra) because MenuBarExtra
    // doesn't expose the NSStatusItem.button needed for right-click
    // context menus. The popover content and label are still SwiftUI
    // — we host them in NSHostingView/NSHostingController.
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var menuBarHostingView: NSHostingView<AnyView>?
    private var menuBarPrefObserver: NSObjectProtocol?

    override init() {
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
        // Clear any "Pacer paused" banner left over from a previous
        // quit. We're alive again, the user is here — the "reopen
        // Pacer" prompt is moot. Also preempts a pending request that
        // the prior process scheduled but couldn't fully deliver
        // before SIGKILL during a dev-cycle quit→relaunch.
        NotificationCoordinator.shared.clearCollectionPausedNotification()
        backgroundService.start()
        installWindowObservers()
        installMenuBar()
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
                self?.applyActivationPolicyForCurrentWindows()
                if let window {
                    Self.ensureWindowAutosaves(window)
                    Self.ensureWindowOnScreen(window)
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

    /// SwiftUI's `Window` scene typically auto-sets a non-empty
    /// `frameAutosaveName` from the scene id ("main" → some derived
    /// name) — but the exact behavior has shifted across macOS
    /// releases and at least one Sequoia point release left it empty
    /// in dev builds. Lock in an explicit autosave name on the main
    /// window so frame size + position reliably persist across
    /// launches, regardless of what the OS-default would have been.
    private static func ensureWindowAutosaves(_ window: NSWindow) {
        guard window.canBecomeMain, !(window is NSPanel) else { return }
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("PacerMainWindow")
        }
    }

    /// macOS persists the main window's frame across launches via the
    /// `frameAutosaveName`. If the user moved the window onto a
    /// secondary display and then disconnected it, the restored frame
    /// can sit entirely off-screen — the user opens "Pacer" from the
    /// menu bar, sees nothing, and has no obvious way back. This
    /// reseats the window centered on the main screen whenever its
    /// saved frame doesn't intersect any current screen.
    private static func ensureWindowOnScreen(_ window: NSWindow) {
        // Skip auxiliary windows (panels, menu-bar popover host) — only
        // the main "Pacer" window needs reseating.
        guard window.canBecomeMain, !(window is NSPanel) else { return }
        let frame = window.frame
        let visible = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(frame)
        }
        guard !visible else { return }
        // Center on the screen that currently has the menu bar (the
        // user's primary), then save the new frame so the next launch
        // doesn't repeat the dance.
        guard let target = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = target.visibleFrame
        let newFrame = NSRect(
            x: v.midX - frame.width / 2,
            y: v.midY - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
        window.setFrame(newFrame, display: true, animate: false)
        window.saveFrame(usingName: window.frameAutosaveName)
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
        let target: NSApplication.ActivationPolicy =
            visibleMainWindows.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
    }

    // MARK: - Menu bar (custom NSStatusItem)

    /// Bring up the status item if the user's preference is anything
    /// other than `.hidden`. Subscribes to App Group `UserDefaults`
    /// changes so a flip in Settings → Menu Bar adds/removes the icon
    /// without a relaunch.
    private func installMenuBar() {
        rebuildMenuBarForCurrentStyle()
        // App Group UserDefaults posts didChangeNotification on every
        // write; cheaper to gate on "did the style key actually change"
        // than to rebuild on every settings flip.
        var lastStyle = currentMenuBarStyle()
        menuBarPrefObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: PacerSettings.store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = self.currentMenuBarStyle()
                if now != lastStyle {
                    lastStyle = now
                    self.rebuildMenuBarForCurrentStyle()
                }
            }
        }
    }

    private func currentMenuBarStyle() -> PacerSettings.MenuBarStyle {
        let raw = PacerSettings.store.string(forKey: PacerSettings.Key.menuBarStyle) ?? ""
        return PacerSettings.MenuBarStyle(rawValue: raw) ?? .iconAndPercent
    }

    private func rebuildMenuBarForCurrentStyle() {
        let style = currentMenuBarStyle()
        if style == .hidden {
            teardownMenuBar()
        } else if statusItem == nil {
            buildStatusItem()
        }
        // For non-hidden style changes (icon/percent toggles, icon
        // variant), the SwiftUI MenuBarLabel inside the hosting view
        // already reacts via @AppStorage — no rebuild needed.
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            return
        }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        // Receive both buttons so we can branch left → popover,
        // right → context menu in the action handler.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Host MenuBarLabel as a SwiftUI view inside the button. We
        // get @Query reactivity, the pulse animation, and tooltip
        // for free; AutoLayout sizes the button to fit the label's
        // intrinsic content width.
        let host = NSHostingView(
            rootView: AnyView(
                MenuBarLabel()
                    .modelContainer(container)
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        // Flush leading/trailing — the menu-bar HIG sizes status items
        // off their content's intrinsic width. The earlier ±4pt insets
        // made Pacer's status item visibly fatter than Battery /
        // Bluetooth / iCloud / etc. when displayed side-by-side. Let
        // the SwiftUI label own all its padding.
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        menuBarHostingView = host
        statusItem = item
    }

    private func teardownMenuBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        menuBarHostingView = nil
        statusPopover?.close()
        statusPopover = nil
    }

    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showStatusContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover = statusPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        if statusPopover == nil {
            let p = NSPopover()
            // .transient so clicking outside dismisses, matching the
            // behavior MenuBarExtra had.
            p.behavior = .transient
            p.animates = true
            let host = NSHostingController(
                rootView: MenuBarContent(onDismiss: { [weak self] in
                    self?.statusPopover?.performClose(nil)
                })
                    .modelContainer(container)
            )
            p.contentViewController = host
            statusPopover = p
        }
        statusPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showStatusContextMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

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

        // popUp(positioning:at:in:) shows the menu under the button
        // without keeping `statusItem.menu` set — that property would
        // otherwise hijack subsequent left-clicks too.
        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func menuOpenMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func menuOpenSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .pacerOpenSettings, object: nil)
    }
}
