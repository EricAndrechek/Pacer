import AppKit
import Observation
import PacerCore
import Sparkle

/// Installs Pacer's updates at a moment nobody will notice, and installs the
/// newest release once rather than a held older one and then the newest (#470).
///
/// **Download at the install moment (#470).** A background check that finds an
/// update does not download it: `UpdateDeferral` vetoes it in
/// `shouldProceedWithUpdate` and the update becomes *available* (pending, its
/// first sighting persisted). Checks keep running every six hours meanwhile,
/// and a newer release replaces the pending one. When `UpdateInstallPolicy`
/// says install, or someone clicks "Restart to Update", the scheduler *arms*:
/// it calls `checkForUpdatesInBackground()` and lets that check through, so
/// Sparkle reads the feed then, downloads the newest release (its delta when
/// there is one), and hands over the install block, which fires at once. The
/// pure rules, and the Sparkle source lines they rely on, are in
/// `UpdateDeferral` and `UpdateSchedule` (PacerCore).
///
/// **The hold** (since 0.8.3). Without it, Sparkle 2.10 leaves a downloaded
/// update's installer waiting for the app to terminate
/// (`SPUAutomaticUpdateDriver.m` `installerDidFinishPreparationAndWillInstallImmediately:`),
/// which for a menu-bar agent is never; every later check resumes that
/// installer without reading the feed (`SPUUpdater.m:904-906`). Returning YES
/// from `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` keeps
/// the automatic driver alive with the block in hand, which holds Sparkle's
/// session open (no check starts: `SPUUpdater.m:597`, `:664`, `:713`). The block
/// installs and relaunches with no UI (`finishInstallationWithResponse:…
/// displayingUserInterface:NO`). An armed hold is called at once; a hold no arm
/// led to (an update pending for `UpdateDeferral.fallbackAfter`, a critical
/// one) waits for the policy as before #470, bounded by `maxWait` and
/// `ceiling`. If Pacer quits first, Sparkle installs on quit as it always did.
/// An update that is only available is not installed on quit: nothing is
/// downloaded yet. That is the cost, bounded by the 72 h fallback.
///
/// Reads the Mac only while an update is pending or held, on a one-minute
/// timer. One app-lifetime observer, for a rare event.
@MainActor @Observable
final class UpdateInstallScheduler {

    /// Timings and a hook on the Mac's signals. Pacer never changes them: the
    /// update end-to-end test app (`UpdateE2E/`, `.github/workflows/update-e2e.yml`)
    /// sets them before first touching `shared`, so a CI runner can reach the
    /// install moment in seconds instead of ten idle minutes.
    struct Tuning {
        var tick: TimeInterval = 60
        var armSpacing: TimeInterval = UpdateSchedule.armSpacing
        var retryAfter: TimeInterval = 15 * 60
        var adjustSignals: (@MainActor (inout UpdateInstallPolicy.Signals) -> Void)?
    }

    static var tuning = Tuning()

    static let shared = UpdateInstallScheduler()

    /// Idle, available, arming, held or installing: read by `UpdateStatus`
    /// for every surface, so observed.
    private(set) var schedule: UpdateSchedule

    /// The version Sparkle's install block would install (held or installing).
    var readyVersion: String? { schedule.heldVersion }
    /// What the update action offers: pending or held.
    var offeredVersion: String? { schedule.offeredVersion }
    /// The block has been called and Pacer has not relaunched yet, or an arm
    /// someone clicked for is downloading: the update buttons grey out, and a
    /// second click does nothing. Back to clickable when the hold ends, an arm
    /// fails, or `retryAfter` passes with Pacer still here (the block can be
    /// called again then).
    var isInstalling: Bool { schedule.isInstalling }

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
    /// Only the user's own app defers, arms and writes the shared defaults: a
    /// render or a probe of the bundle leaves Sparkle as it was before #470.
    @ObservationIgnored private let owner = LaunchMode.isNormalLaunch
    @ObservationIgnored private let currentBuild =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    @ObservationIgnored private let tuning = UpdateInstallScheduler.tuning

    private init() {
        let store = PacerPreferences.store
        if owner {
            let saved = UpdateScheduleStore.load(store)
            schedule = UpdateSchedule(restoring: saved.pending, lastAttempt: saved.lastAttempt,
                                      currentBuild: currentBuild)
            if UpdateScheduleStore.takeArmedInstall(currentBuild: currentBuild, store) {
                TelemetryCounters.add(UpdateSchedule.ArmOutcome.installed.counterKey)
            }
            UpdateScheduleStore.save(schedule, store)
        } else {
            schedule = UpdateSchedule()
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastResignedActive = Date() }
        })
        if let pending = schedule.pending {
            Log.write("Update", "\(pending.version) available since \(Self.stamp(pending.since)); downloads when Pacer can install it")
        }
    }

    // MARK: - From the app

    /// The store is open: no migration can be running any more.
    func noteStoreReady() { storeReady = true }

    /// The updater the scheduler arms. `PacerUpdater` hands it over once
    /// Sparkle's controller exists; the timer starts if an update was pending
    /// at launch.
    func attach(_ updater: SPUUpdater) {
        self.updater = updater
        if schedule.needsTimer { startTimer() }
    }

    // MARK: - From Sparkle's delegate

    /// `shouldProceedWithUpdate`: defer the download, or let it go ahead.
    func decide(_ found: UpdateDeferral.Found, version: String, build: String) -> UpdateDeferral.Decision {
        let now = Date()
        let pendingFor = schedule.pending.map { max(0, now.timeIntervalSince($0.since)) }
        let decision = UpdateDeferral.decide(found, normalLaunch: owner, arming: schedule.isArming,
                                             pendingFor: pendingFor)
        switch decision {
        case .defer:
            if schedule.deferred(version: version, build: build, now: now, currentBuild: currentBuild) {
                Log.write("Update", "\(version) available; downloads when Pacer can install it")
                UpdateOutcomeLog.record(.available, version: version)
                persist()
            }
            startTimer()
        case .proceed(.arming):
            Log.write("Update", "downloading \(version) to install it")
        case .proceed(.fallback):
            // The arming step has not managed it in three days: download now
            // and let the hold and install-on-quit take it, as before #470.
            Log.write("Update", "\(version) pending for 72 h; downloading it now")
            TelemetryCounters.add("update.defer_fallback")
        case .proceed(.needsAttention), .proceed(.notAutomatic):
            // Sparkle's own handling from here: nothing of ours is pending.
            if schedule.pending != nil, !schedule.isHeldOrInstalling {
                schedule.clear()
                persist()
            }
        case .proceed(.userCheck), .proceed(.diagnosticLaunch):
            break
        }
        return decision
    }

    /// `willInstallUpdateOnQuit`: take the install over. False leaves Sparkle's
    /// own install-on-quit alone, for a diagnostic run of the bundle.
    func hold(version: String, updater: SPUUpdater, install: @escaping () -> Void) -> Bool {
        guard owner else { return false }
        self.install = install
        self.updater = updater
        firedAt = nil
        lastWait = nil
        let action = schedule.held(version: version)
        persist()
        startTimer()
        switch action {
        case .installNow:
            TelemetryCounters.add(UpdateSchedule.ArmOutcome.held.counterKey)
            readyAt = Date()
            Log.write("Update", "\(version) downloaded on request")
            fire(reason: "chosen", byPolicy: false)
        case .evaluate(let since):
            TelemetryCounters.add(UpdateSchedule.ArmOutcome.held.counterKey)
            // From the first sighting: the policy said install a moment ago,
            // and says it again unless someone has come back since.
            readyAt = since
            Log.write("Update", "\(version) downloaded at the install moment")
            evaluate()
        case .hold:
            readyAt = Date()
            Log.write("Update", "\(version) downloaded; installs when Pacer is not in use")
            evaluate()
        }
        return true
    }

    /// Sparkle's session ended (an error, or anything else that dropped the
    /// driver): the block in hand installs nothing now. A pending update is
    /// pending again, and its next arm reads the feed afresh.
    func release() {
        guard install != nil else { return }
        Log.write("Update", "\(readyVersion ?? "update") no longer waiting")
        install = nil
        readyAt = nil
        firedAt = nil
        installingByPolicy = false
        schedule.released()
        persist()
        if !schedule.needsTimer { stopTimer() }
    }

    /// A cycle ended without a hold in hand (`didFinishUpdateCycle`, after
    /// `release`). While arming, that is the arm's outcome.
    func cycleEnded(_ end: UpdateSchedule.CycleEnd) {
        let wasPending = schedule.pending?.version
        if let outcome = schedule.cycleEnded(end) {
            TelemetryCounters.add(outcome.counterKey)
            Log.write("Update", "arm for \(wasPending ?? "update"): \(outcome.rawValue)")
        } else if wasPending != nil, schedule.pending == nil {
            Log.write("Update", "\(wasPending ?? "update") no longer offered")
        }
        persist()
        if !schedule.needsTimer { stopTimer() }
    }

    func noteRelaunching() {
        isRelaunchingForUpdate = true
        // Sparkle relaunches the new version from here; the crash relauncher
        // starting this one again would race it (#412).
        CrashRelauncher.standDown()
    }

    /// "Restart to Update" / "Update to … — Restart" (`UpdateStatus.installNow`):
    /// someone asked, so no policy applies. That includes the editing guard, on
    /// purpose: the policy never relaunches over text being typed because
    /// nobody asked it to, and here somebody did, with a click (the field that
    /// was being edited lost focus to it). An update that is only available is
    /// downloaded first and installed the moment Sparkle hands it over.
    func installNow() {
        guard owner, let updater else { return }
        if !schedule.isHeldOrInstalling, schedule.pending != nil,
           !(updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates) {
            dropOptedOut()
            return
        }
        switch schedule.clicked(sessionInProgress: updater.sessionInProgress) {
        case .installHeld:
            guard install != nil, !schedule.isInstalling else { return }
            // The same check the timer makes: a session that closed without
            // telling the delegate leaves a block that installs nothing.
            guard updater.sessionInProgress else { release(); return }
            fire(reason: "chosen", byPolicy: false)
        case .arm:
            arm(.requested)
        case .waiting:
            if schedule.noteBusy() { TelemetryCounters.add(UpdateSchedule.ArmOutcome.busy.counterKey) }
            Log.write("Update", "install requested; Sparkle is busy, arming when it is free")
            startTimer()
        case .nothing:
            break
        }
    }

    // MARK: - Deciding

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: tuning.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = min(15, tuning.tick / 4)
        // Default mode only, so it never fires while a menu is open.
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func evaluate() {
        switch schedule.phase {
        case .idle:
            stopTimer()
        case .available(let pending):
            evaluateArming(since: pending.since)
        case .arming:
            // Sparkle tells the delegate when the cycle ends; if a session
            // ever closed without that, the arm is over all the same.
            if updater?.sessionInProgress != true { cycleEnded(.other) }
        case .held, .installing:
            evaluateHold()
        }
    }

    private func evaluateArming(since: Date) {
        guard let updater else { return }
        let now = Date()
        let policy = UpdateInstallPolicy.decide(signals(now: now, readyAt: since))
        let verdict = schedule.armVerdict(
            now: now, policy: policy, sessionInProgress: updater.sessionInProgress,
            automaticChecks: updater.automaticallyChecksForUpdates,
            automaticDownloads: updater.automaticallyDownloadsUpdates,
            spacing: tuning.armSpacing)
        switch verdict {
        case .arm(let reason):
            arm(reason)
        case .wait(let reason):
            if reason != lastWait {
                lastWait = reason
                Log.write("Update", "arming waits: \(reason.rawValue)")
            }
        case .busy:
            if schedule.noteBusy() { TelemetryCounters.add(UpdateSchedule.ArmOutcome.busy.counterKey) }
        case .optedOut:
            dropOptedOut()
        case .spacing, .none:
            break
        }
    }

    /// Start the check that downloads. `checkForUpdatesInBackground()` begins
    /// Sparkle's session synchronously (`SPUUpdater.m:603-606`) or refuses
    /// without one (`:658-666`), so `sessionInProgress` right after it says
    /// which.
    private func arm(_ reason: UpdateSchedule.ArmReason) {
        guard let updater, let version = schedule.pending?.version else { return }
        schedule.armed(reason, now: Date())
        persist()
        lastWait = nil
        Log.write("Update", "arming for \(version) (\(reason.rawValue)): reading the feed")
        updater.checkForUpdatesInBackground()
        if !updater.sessionInProgress {
            schedule.armDidNotStart()
            persist()
            TelemetryCounters.add(UpdateSchedule.ArmOutcome.busy.counterKey)
            Log.write("Update", "arming did not start")
        }
    }

    private func dropOptedOut() {
        guard let version = schedule.pending?.version else { return }
        schedule.clear()
        persist()
        Log.write("Update", "\(version) no longer pending: automatic updates are off")
        if !schedule.needsTimer { stopTimer() }
    }

    private func evaluateHold() {
        guard install != nil, let readyAt else { return }
        // The documented contract keeps the session open while the driver
        // holds the block; if it ever closes without telling the delegate,
        // the block is dead and "Update to … — Restart" would do nothing.
        guard updater?.sessionInProgress == true else { release(); return }
        let now = Date()
        if let firedAt {
            if now.timeIntervalSince(firedAt) < tuning.retryAfter { return }
            // Still here after the wait: the block may be called again.
            self.firedAt = nil
            schedule.installDidNotHappen()
        }
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
        if case .held(_, _, let armed) = schedule.phase, armed != nil, owner {
            UpdateScheduleStore.noteArmedInstall(fromBuild: currentBuild, PacerPreferences.store)
        }
        firedAt = Date()
        schedule.fired()
        installingByPolicy = byPolicy
        install?()
    }

    private func persist() {
        guard owner else { return }
        UpdateScheduleStore.save(schedule, PacerPreferences.store)
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
    }

    /// A window's first responder holds text someone has changed since it
    /// took focus (`UpdateInstallPolicy.isEditing`). Typing into any text
    /// field, SwiftUI's included, goes to the window's field editor, an
    /// `NSTextView`; its undo manager records each edit, and an IME
    /// composition shows as marked text before it does. Focus alone is not
    /// editing. Per window, not only the key one: the field editor stays first
    /// responder of a window that has lost key status, with its text unsent.
    /// A few property reads per visible window, once a minute while an update
    /// waits.
    private static func holdsEditedText(_ responder: NSResponder?) -> Bool {
        // An `NSTextField` that is itself first responder has not handed
        // typing to its field editor yet, so nothing has been typed into it.
        guard let text = responder as? NSTextView else { return false }
        return UpdateInstallPolicy.isEditing(.init(
            editable: text.isEditable,
            allowsUndo: text.allowsUndo,
            canUndo: text.undoManager?.canUndo ?? false,
            hasMarkedText: text.hasMarkedText()))
    }

    private func signals(now: Date, readyAt: Date) -> UpdateInstallPolicy.Signals {
        var dashboardOnScreen = false
        var otherWindowOpen = NSApp.modalWindow != nil
        // A sheet or modal panel's contents can't be told apart from a form
        // half filled in, so either counts as editing.
        var editingText = NSApp.modalWindow != nil
        for window in NSApp.windows where window.isVisible {
            if window.attachedSheet != nil { otherWindowOpen = true; editingText = true }
            if Self.holdsEditedText(window.firstResponder) { editingText = true }
            if MainWindowPlacement.isDashboard(window) {
                dashboardOnScreen = true
            } else if window.canBecomeMain, !(window is NSPanel) {
                // The filter the Dock policy uses for "a window is open":
                // About, a problem report, Sparkle's own alert.
                otherWindowOpen = true
            }
        }
        let lastUsed = max(launchedAt, lastResignedActive ?? launchedAt)
        var signals = UpdateInstallPolicy.Signals(
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
            editingText: editingText,
            // `wasOpen` is what the relaunch restores (MainWindowPlacement),
            // so a minimised or hidden dashboard counts: it comes back on
            // screen.
            dashboardOpen: dashboardOnScreen || MainWindowPlacement.wasOpen,
            storeOpening: !storeReady)
        tuning.adjustSignals?(&signals)
        return signals
    }
}

private extension UpdateSchedule {
    var isHeldOrInstalling: Bool {
        switch phase {
        case .held, .installing: return true
        default: return false
        }
    }
}
