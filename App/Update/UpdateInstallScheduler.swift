import AppKit
import Observation
import PacerCore
import Sparkle

/// Installs an update Sparkle has downloaded at a moment nobody will notice,
/// instead of when Pacer quits, which for a menu-bar agent is never.
///
/// **What Sparkle does without this** (2.10, `SPUAutomaticUpdateDriver.m`
/// `installerDidFinishPreparationAndWillInstallImmediately:`): the update is
/// downloaded, its installer prepared and left waiting for the app to
/// terminate, and the session ends. From then on every check, scheduled
/// (`SPUUpdater.m` `_checkForUpdatesInBackground`) or the user's own
/// (`checkForUpdates`), finds that installer running and calls
/// `resumeInstallingUpdate`, which asks the installer for *its* update
/// (`SPUBasicUpdateDriver.m` `resumeInstallingUpdate`) and never reads the
/// feed. And the scheduler waits `max(interval, impatient interval)`, a week,
/// before even that (`scheduleNextUpdateCheckFiringImmediately:`). So a newer
/// release behind the waiting one is invisible until the waiting one is
/// installed: two update rounds, days apart.
///
/// **What this does instead.** Returning YES from
/// `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` keeps the
/// automatic driver alive with the block in hand, which holds Sparkle's
/// session open: no check of any kind starts while an update waits here
/// (`updaterTimerDidFire` and `checkForUpdates` both return on
/// `sessionInProgress`), so nothing can resume a stale update and no second
/// one can stack up behind it. The block installs and relaunches with no UI
/// (`finishInstallationWithResponse:… displayingUserInterface:NO`).
/// `UpdateInstallPolicy` says when; `maxWait` bounds the hold, so the feed is
/// never left unread for long. The next launch reads the feed as usual.
/// If Pacer quits first, Sparkle installs on quit as it always did.
///
/// Reads the Mac only while an update waits, on a one-minute timer. One
/// app-lifetime observer, for a rare event.
@MainActor @Observable
final class UpdateInstallScheduler {

    static let shared = UpdateInstallScheduler()

    /// The version waiting to be installed. "Check for Updates…" turns into
    /// "Relaunch to Update" while there is one, since no check can run.
    private(set) var readyVersion: String?

    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private weak var updater: SPUUpdater?
    @ObservationIgnored private var readyAt: Date?
    @ObservationIgnored private var firedAt: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastWait: UpdateInstallPolicy.WaitReason?

    /// The install in progress was the policy's, not someone's click: the
    /// telemetry outcome says which.
    @ObservationIgnored private(set) var installingByPolicy = false
    /// Sparkle is about to relaunch Pacer (any install, the dialog's too).
    @ObservationIgnored private(set) var isRelaunchingForUpdate = false

    @ObservationIgnored private var storeReady = false
    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private var lastResignedActive: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The block can be called again if a termination did not happen (Sparkle
    /// 2.3+); this spaces the retries.
    private static let retryAfter: TimeInterval = 15 * 60
    private static let tick: TimeInterval = 60

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastResignedActive = Date() }
        })
    }

    // MARK: - From the app

    /// The store is open: no migration can be running any more.
    func noteStoreReady() { storeReady = true }

    // MARK: - From Sparkle's delegate

    /// `willInstallUpdateOnQuit`: take the install over. False leaves Sparkle's
    /// own install-on-quit alone, for a diagnostic run of the bundle.
    func hold(version: String, updater: SPUUpdater, install: @escaping () -> Void) -> Bool {
        guard LaunchMode.isNormalLaunch else { return false }
        self.install = install
        self.updater = updater
        readyVersion = version
        readyAt = Date()
        firedAt = nil
        lastWait = nil
        Log.write("Update", "\(version) downloaded; installs when Pacer is not in use")
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 15
        // Default mode only, so it never fires while a menu is open.
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
        evaluate()
        return true
    }

    /// Sparkle's session ended (an error, or anything else that dropped the
    /// driver): the block in hand installs nothing now.
    func release() {
        guard install != nil else { return }
        Log.write("Update", "\(readyVersion ?? "update") no longer waiting")
        install = nil
        updater = nil
        readyVersion = nil
        readyAt = nil
        firedAt = nil
        installingByPolicy = false
        timer?.invalidate()
        timer = nil
    }

    func noteRelaunching() {
        isRelaunchingForUpdate = true
        // Sparkle relaunches the new version from here; the crash relauncher
        // starting this one again would race it (#412).
        CrashRelauncher.standDown()
    }

    /// "Relaunch to Update": someone asked, so no policy applies.
    func installNow() {
        guard install != nil else { return }
        fire(reason: "chosen", byPolicy: false)
    }

    // MARK: - Deciding

    private func evaluate() {
        guard install != nil, let readyAt else { return }
        // The documented contract keeps the session open while the driver
        // holds the block; if it ever closes without telling the delegate,
        // the block is dead and "Relaunch to Update" would do nothing.
        guard updater?.sessionInProgress == true else { release(); return }
        let now = Date()
        if let firedAt, now.timeIntervalSince(firedAt) < Self.retryAfter { return }
        switch UpdateInstallPolicy.decide(signals(now: now, readyAt: readyAt)) {
        case .wait(let reason):
            if reason != lastWait {
                lastWait = reason
                Log.write("Update", "install waiting: \(reason.rawValue)")
            }
        case .install(let reason):
            fire(reason: reason.rawValue, byPolicy: true)
        }
    }

    private func fire(reason: String, byPolicy: Bool) {
        Log.write("Update", "installing \(readyVersion ?? "update") (\(reason)); Pacer relaunches")
        firedAt = Date()
        installingByPolicy = byPolicy
        install?()
    }

    private func signals(now: Date, readyAt: Date) -> UpdateInstallPolicy.Signals {
        var dashboardOnScreen = false
        var otherWindowOpen = NSApp.modalWindow != nil
        for window in NSApp.windows where window.isVisible {
            if window.attachedSheet != nil { otherWindowOpen = true }
            if MainWindowPlacement.isDashboard(window) {
                dashboardOnScreen = true
            } else if window.canBecomeMain, !(window is NSPanel) {
                // The filter the Dock policy uses for "a window is open":
                // About, a problem report, Sparkle's own alert.
                otherWindowOpen = true
            }
        }
        let lastUsed = max(launchedAt, lastResignedActive ?? launchedAt)
        return UpdateInstallPolicy.Signals(
            sinceReady: now.timeIntervalSince(readyAt),
            sinceUsed: now.timeIntervalSince(lastUsed),
            // The arena's idle clock: the window server's time since the last
            // input event, read, never posted.
            userIdle: ArenaBudgetSignals.current().idleSeconds,
            pacerActive: NSApp.isActive,
            // A menu tracks in its own run-loop mode, the status item's and
            // the main menu's alike. Asked of the run loop rather than kept
            // from begin/end notifications, so it cannot stick.
            menuOpen: RunLoop.current.currentMode == .eventTracking,
            otherWindowOpen: otherWindowOpen,
            // `wasOpen` is what the relaunch restores (MainWindowPlacement),
            // so a minimised or hidden dashboard counts: it comes back on
            // screen.
            dashboardOpen: dashboardOnScreen || MainWindowPlacement.wasOpen,
            storeOpening: !storeReady)
    }
}
