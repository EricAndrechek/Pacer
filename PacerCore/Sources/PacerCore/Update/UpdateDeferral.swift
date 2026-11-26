import Foundation

/// Whether Pacer lets Sparkle download an update a check has just found, or
/// only notes that it is there and downloads it at the moment it can install
/// it (#470).
///
/// **Why.** A downloaded update waits for a quiet moment (`UpdateInstallPolicy`),
/// and while it waits Sparkle reads no feed: the hold keeps its session open and
/// every check returns on `sessionInProgress` (Sparkle 2.10.1 `SPUUpdater.m:597`,
/// `:664`, `:713`, `:760`; `resetUpdateCycle` does nothing either, `:964`). Once
/// the session ends, a prepared installer is resumed without reading the feed
/// (`SPUUpdater.m:904-906`, `SPUBasicUpdateDriver.m:100-109`). So a Mac that held
/// 0.9.5 for days installed 0.9.5, then found 0.9.6 on its next check and
/// installed again. Sparkle has no supported way to drop a held update (the
/// only clean cancel, `SPUCancelInstallation`, is sent for a Skip,
/// `SPUCoreBasedUpdateDriver.m:313-315` → `SPUInstallerDriver.m:563-573`, which
/// a UI driver reaches and which also marks the version skipped), so the hold cannot be swapped
/// for a newer one. Not downloading until the install moment avoids the hold
/// going stale at all.
///
/// **How.** `updater(_:shouldProceedWithUpdate:updateCheck:)` runs after the feed
/// is read and the best item chosen, and before anything is downloaded or
/// `didFindValidUpdate` is called (`SPUBasicUpdateDriver.m:150-158`; not on a
/// resumed update, `resuming:YES`; the Swift form of the delegate method
/// `SPUUpdaterDelegate.h:241-252` declares). Throwing there aborts the cycle
/// with that error (`SPUCoreBasedUpdateDriver.m:356-360` →
/// `SPUAutomaticUpdateDriver.m:131-134`, `:146-153`), keeps nothing resumable
/// (`SPUCoreBasedUpdateDriver.m:388`), and the next check is scheduled at the
/// normal interval (`SPUAutomaticUpdateDriver.m:150` gives NO to "show next
/// update immediately" for any error but 4008; `SPUUpdater.m:872`, `:889`).
/// When `UpdateSchedule` arms, Pacer calls `checkForUpdatesInBackground()` and
/// this lets that check through: Sparkle reads the feed then, picks the newest
/// item and its delta (`SUAppcastDriver.m:451`), downloads it, and hands the
/// install block over (`SPUAutomaticUpdateDriver.m:104-129`).
///
/// Deferred are only the updates Sparkle would download silently anyway: a
/// background check with automatic downloads on, and neither critical,
/// information-only nor a major upgrade (those Sparkle shows or installs on its
/// own terms, `SPUAutomaticUpdateDriver.m:82-97`). And only for
/// `fallbackAfter`: an update pending longer is let through, and the hold and
/// install-on-quit take over as before #470, which bounds any bug in arming.
public enum UpdateDeferral {

    /// What Sparkle's `shouldProceedWithUpdate` knows, as plain values.
    public struct Found: Sendable, Equatable {
        /// `.updatesInBackground`: the launch and scheduled checks and every
        /// `checkForUpdatesInBackground()` Pacer makes. Not the user's "Check
        /// for Updates…" (`.updates`), and not the information probe.
        public var background: Bool
        /// `SPUUpdater.automaticallyDownloadsUpdates`. Off, a background check
        /// runs Sparkle's scheduled driver, which asks before downloading
        /// (`SPUUpdater.m:622-639`): nothing to defer.
        public var automaticDownloads: Bool
        public var critical: Bool
        public var informationOnly: Bool
        public var majorUpgrade: Bool

        public init(background: Bool, automaticDownloads: Bool, critical: Bool = false,
                    informationOnly: Bool = false, majorUpgrade: Bool = false) {
            self.background = background; self.automaticDownloads = automaticDownloads
            self.critical = critical; self.informationOnly = informationOnly; self.majorUpgrade = majorUpgrade
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Note the update and download nothing: the veto.
        case `defer`
        case proceed(Proceed)
    }

    public enum Proceed: String, Sendable, Equatable {
        /// Someone chose "Check for Updates…": Sparkle's own dialog, as before.
        case userCheck = "user check"
        /// Automatic downloads are off: Sparkle asks first, as before.
        case notAutomatic = "not automatic"
        /// Critical, information-only or a major upgrade: Sparkle's own handling.
        case needsAttention = "needs attention"
        /// Not the user's own app (a render, a probe, a test): no deferral and
        /// nothing written to the defaults the real app shares.
        case diagnosticLaunch = "diagnostic launch"
        /// The install moment: this check downloads, and the hold installs.
        case arming
        /// Pending for `fallbackAfter`: the hold and install-on-quit take over.
        case fallback
    }

    /// How long an update may stay pending before it is downloaded the way it
    /// was before #470. Three days, the same as `UpdateInstallPolicy.ceiling`:
    /// arming normally happens within the hour of someone leaving the Mac.
    public static let fallbackAfter: TimeInterval = 72 * 3600

    /// `pendingFor`: how long an update has been pending (any version), nil
    /// when none is.
    public static func decide(_ found: Found, normalLaunch: Bool, arming: Bool,
                              pendingFor: TimeInterval?) -> Decision {
        guard found.background else { return .proceed(.userCheck) }
        guard normalLaunch else { return .proceed(.diagnosticLaunch) }
        guard found.automaticDownloads else { return .proceed(.notAutomatic) }
        if found.critical || found.informationOnly || found.majorUpgrade { return .proceed(.needsAttention) }
        if arming { return .proceed(.arming) }
        if let pendingFor, pendingFor >= fallbackAfter { return .proceed(.fallback) }
        return .defer
    }

    /// The veto's error. Pacer's own domain, and a code Sparkle does not use:
    /// Sparkle compares error codes without their domain (`SPUUpdater.m:798`,
    /// `:803`; `SPUAutomaticUpdateDriver.m:150`; `SPUCoreBasedUpdateDriver.m:388`;
    /// `SPUUIBasedUpdateDriver.m:464`, `:482`), so 1001 would read as "no
    /// update", 4007 as a cancelled install, and 4008 would keep the update
    /// resumable and start the next check at once.
    public static let errorDomain = "com.ericandrechek.pacer.update"
    public static let errorCode = 470

    public static func isDeferral(domain: String, code: Int) -> Bool {
        domain == errorDomain && code == errorCode
    }

    public static func error(version: String) -> NSError {
        NSError(domain: errorDomain, code: errorCode, userInfo: [
            // Sparkle's contract: the description must be set (SPUUpdaterDelegate.h:249).
            NSLocalizedDescriptionKey: "Pacer \(version) downloads when Pacer can install it.",
        ])
    }
}

/// Where the install-newest scheduler stands, apart from AppKit and Sparkle:
/// idle → available → arming → held → installing. `UpdateInstallScheduler` in
/// the app reads the Mac and Sparkle and feeds this; every transition is here,
/// so it can be tested.
///
/// - **available**: a background check found an update and the deferral said
///   wait (`UpdateDeferral`). Its first sighting is kept (`since`), across
///   launches: it is both the deferral's 72 h clock and the policy's "since
///   ready", so a pending update ages the same way a held one did.
/// - **arming**: `UpdateInstallPolicy` said install (or someone clicked), Sparkle
///   is idle, and the last attempt is `armSpacing` old: Pacer has started a
///   background check that downloads.
/// - **held**: Sparkle handed over its install block (`willInstallUpdateOnQuit`).
/// - **installing**: the block was called; Pacer relaunches.
public struct UpdateSchedule: Sendable, Equatable {

    public struct Pending: Codable, Sendable, Equatable {
        /// The newest version a check has deferred: what the action offers.
        public var version: String
        /// Its `CFBundleVersion`, which tells a newer item from the same one.
        public var build: String
        /// When an update was first deferred.
        public var since: Date
        /// This Pacer's `CFBundleVersion` then. A launch on any other build has
        /// installed something since, and starts clean.
        public var fromBuild: String

        public init(version: String, build: String, since: Date, fromBuild: String) {
            self.version = version; self.build = build; self.since = since; self.fromBuild = fromBuild
        }
    }

    public enum ArmReason: String, Sendable, Equatable {
        /// `UpdateInstallPolicy` said install.
        case policy
        /// Someone clicked "Restart to Update" / "Update to … — Restart".
        case requested
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case available(Pending)
        case arming(Pending, ArmReason)
        /// Sparkle's install block in hand. `pending` and `armed` are nil for a
        /// hold no arming led to: the 72 h fallback, a critical update.
        case held(version: String, pending: Pending?, armed: ArmReason?)
        case installing(version: String, pending: Pending?, armed: ArmReason?)
    }

    /// What an arm attempt came to, for the `update.arm.*` counters.
    public enum ArmOutcome: String, Sendable, Equatable, CaseIterable {
        /// Downloaded and handed over.
        case held
        /// The armed install relaunched into a new build (counted at that launch).
        case installed
        /// The check found nothing newer than this build: the update was pulled.
        case nothingNewer = "nothing_newer"
        case feedFailed = "feed_failed"
        /// The feed was read but the download (or its extraction) failed.
        case downloadFailed = "download_failed"
        /// Sparkle was busy with another session when Pacer wanted to arm.
        case busy

        public var counterKey: String { "update.arm.\(rawValue)" }
    }

    /// How a cycle Pacer cares about ended, from Sparkle's delegate.
    public enum CycleEnd: Sendable, Equatable {
        /// Sparkle's "you're up to date" (`SUNoUpdateError`).
        case noUpdate
        /// The appcast could not be read.
        case feedFailed
        /// The appcast was read, and the cycle failed after it.
        case downloadFailed
        /// Anything else: no error and no hold.
        case other

        /// How `didFinishUpdateCycle`'s error reads. Nil for a deferral, which
        /// ends no arm: it is how an update became available. `feedLoaded`:
        /// `didFinishLoadingAppcast` came this cycle (Sparkle wraps a failed
        /// appcast fetch and a failed download in the same 2001).
        public static func classify(errorDomain domain: String?, code: Int?, feedLoaded: Bool) -> CycleEnd? {
            guard let domain, let code else { return .other }
            if UpdateDeferral.isDeferral(domain: domain, code: code) { return nil }
            if UpdateState.isNoUpdate(domain: domain, code: code) { return .noUpdate }
            return feedLoaded ? .downloadFailed : .feedFailed
        }
    }

    public enum ArmVerdict: Sendable, Equatable {
        /// Nothing available to arm.
        case none
        case arm(ArmReason)
        /// The policy says not now.
        case wait(UpdateInstallPolicy.WaitReason)
        /// The last attempt was less than `armSpacing` ago.
        case spacing
        /// Sparkle's session is in progress.
        case busy
        /// Automatic checks or downloads are off: drop the pending update.
        case optedOut
    }

    /// What `held(version:)` asks the scheduler to do with the block.
    public enum HoldAction: Sendable, Equatable {
        /// Someone asked: install at once.
        case installNow
        /// Ask `UpdateInstallPolicy`, counting "since ready" from `since`: the
        /// first sighting of the pending update, or now (nil) for a hold that
        /// had none. An armed hold: the policy said install a moment ago and
        /// says it again unless someone came back. The 72 h fallback: the
        /// policy's `ceiling` is already behind it, so the hold is bounded
        /// from the first sighting, not from the download.
        case policy(since: Date?)
    }

    public enum Click: Sendable, Equatable {
        /// Start the armed check now.
        case arm
        /// Sparkle is busy; arm as soon as it is free.
        case waiting
        /// A hold is in hand: install it.
        case installHeld
        /// Already on its way (an arm that will now install at once, or an install).
        case nothing
    }

    /// Between arm attempts the policy makes: a failed download or an
    /// unreachable feed is retried half an hour later, not every minute.
    public static let armSpacing: TimeInterval = 30 * 60

    public private(set) var phase: Phase
    public private(set) var lastAttempt: Date?
    /// Someone clicked while Sparkle was busy.
    public private(set) var clickWaiting = false
    /// `busy` was counted for the current wish to arm.
    private var busyCounted = false

    public init(phase: Phase = .idle, lastAttempt: Date? = nil) {
        self.phase = phase
        self.lastAttempt = lastAttempt
    }

    /// At launch, from what was persisted. A pending update deferred on another
    /// build of Pacer is gone: this launch is past it, and the next check finds
    /// whatever is newer.
    public init(restoring pending: Pending?, lastAttempt: Date?, currentBuild: String) {
        if let pending, pending.fromBuild == currentBuild {
            self.init(phase: .available(pending), lastAttempt: lastAttempt)
        } else {
            self.init(phase: .idle, lastAttempt: pending == nil ? lastAttempt : nil)
        }
    }

    // MARK: - Reading

    public var pending: Pending? {
        switch phase {
        case .idle: return nil
        case .available(let p), .arming(let p, _): return p
        case .held(_, let p, _), .installing(_, let p, _): return p
        }
    }

    /// The version the update action offers ("Update to 0.9.6 — Restart"):
    /// a held one, or else a pending one.
    public var offeredVersion: String? {
        switch phase {
        case .idle: return nil
        case .available(let p), .arming(let p, _): return p.version
        case .held(let v, _, _), .installing(let v, _, _): return v
        }
    }

    /// The version Sparkle's block would install.
    public var heldVersion: String? {
        switch phase {
        case .held(let v, _, _), .installing(let v, _, _): return v
        default: return nil
        }
    }

    /// The update action shows as under way: an install started, or an arm
    /// someone clicked for (it installs as soon as it is downloaded).
    public var isInstalling: Bool {
        switch phase {
        case .installing, .arming(_, .requested): return true
        default: return false
        }
    }

    public var isArming: Bool {
        if case .arming = phase { return true }
        return false
    }

    /// Anything but idle is watched on the scheduler's timer.
    public var needsTimer: Bool { phase != .idle }

    // MARK: - From Sparkle

    /// A background check found `version` and the deferral said wait. True
    /// when what is offered changed (a first sighting or a newer item), which
    /// is when the scheduler logs it and records `available`.
    @discardableResult
    public mutating func deferred(version: String, build: String, now: Date, currentBuild: String) -> Bool {
        switch phase {
        case .idle:
            phase = .available(Pending(version: version, build: build, since: now, fromBuild: currentBuild))
            busyCounted = false
            return true
        case .available(var p):
            guard p.build != build || p.version != version else { return false }
            // The first sighting stands: the Mac has been behind since then.
            p.version = version
            p.build = build
            phase = .available(p)
            return true
        case .arming, .held, .installing:
            // An arming check is let through, and none runs during a hold.
            return false
        }
    }

    /// The check found something the deferral leaves to Sparkle (critical,
    /// information-only, a major upgrade), or the user turned automatic
    /// downloads off: nothing pending any more. A hold keeps its own course.
    public mutating func clear() {
        switch phase {
        case .available, .arming:
            phase = .idle
            clickWaiting = false
            busyCounted = false
        case .idle, .held, .installing:
            break
        }
    }

    /// The check Pacer started to arm did not start (Sparkle refused it).
    public mutating func armDidNotStart() {
        if case .arming(let p, _) = phase { phase = .available(p) }
    }

    /// Sparkle handed over its install block for `version`.
    public mutating func held(version: String) -> HoldAction {
        switch phase {
        case .arming(let p, let reason):
            phase = .held(version: version, pending: p, armed: reason)
            return reason == .requested ? .installNow : .policy(since: p.since)
        case .available(let p):
            // The fallback: downloaded without arming, after `fallbackAfter`.
            phase = .held(version: version, pending: p, armed: nil)
            return .policy(since: p.since)
        case .idle, .held, .installing:
            // A critical update, or nothing was pending: as before #470.
            phase = .held(version: version, pending: nil, armed: nil)
            return .policy(since: nil)
        }
    }

    /// The block was called.
    public mutating func fired() {
        if case .held(let v, let p, let a) = phase { phase = .installing(version: v, pending: p, armed: a) }
    }

    /// Still here a while after the block was called: it may be called again.
    public mutating func installDidNotHappen() {
        if case .installing(let v, let p, let a) = phase { phase = .held(version: v, pending: p, armed: a) }
    }

    /// Sparkle's session ended with the block unused: the update is pending
    /// again, if it was, and the next arm reads the feed afresh.
    public mutating func released() {
        switch phase {
        case .held(_, let p, _), .installing(_, let p, _):
            phase = p.map(Phase.available) ?? .idle
            clickWaiting = false
            busyCounted = false
        case .idle, .available, .arming:
            break
        }
    }

    /// A cycle ended. While arming, that is the arm's outcome; a cycle that
    /// got to a hold has already moved on. "No update" also drops a pending
    /// update that was only available: it has been pulled from the feed.
    public mutating func cycleEnded(_ end: CycleEnd) -> ArmOutcome? {
        switch phase {
        case .arming(let p, _):
            busyCounted = false
            switch end {
            case .noUpdate:
                phase = .idle
                return .nothingNewer
            case .feedFailed:
                phase = .available(p)
                return .feedFailed
            case .downloadFailed:
                phase = .available(p)
                return .downloadFailed
            case .other:
                phase = .available(p)
                return nil
            }
        case .available:
            if end == .noUpdate { clear() }
            return nil
        case .idle, .held, .installing:
            return nil
        }
    }

    // MARK: - Arming

    /// Whether to arm now. `policy` is `UpdateInstallPolicy.decide` of the
    /// Mac's signals, counting from `pending.since`.
    public func armVerdict(now: Date, policy: UpdateInstallPolicy.Decision, sessionInProgress: Bool,
                           automaticChecks: Bool, automaticDownloads: Bool,
                           spacing: TimeInterval = armSpacing) -> ArmVerdict {
        guard case .available = phase else { return .none }
        // Sparkle does not enforce "check automatically" on a direct
        // `checkForUpdatesInBackground()`, so Pacer does. And with automatic
        // downloads off that call would run Sparkle's dialog-first driver.
        guard automaticChecks, automaticDownloads else { return .optedOut }
        if clickWaiting { return sessionInProgress ? .busy : .arm(.requested) }
        if case .wait(let reason) = policy { return .wait(reason) }
        if let lastAttempt {
            let elapsed = now.timeIntervalSince(lastAttempt)
            // A clock set back must not stall arming until it catches up.
            if elapsed >= 0, elapsed < spacing { return .spacing }
        }
        return sessionInProgress ? .busy : .arm(.policy)
    }

    /// Pacer is starting the armed check.
    public mutating func armed(_ reason: ArmReason, now: Date) {
        guard case .available(let p) = phase else { return }
        phase = .arming(p, reason)
        lastAttempt = now
        clickWaiting = false
        busyCounted = false
    }

    /// True the first time `busy` comes up for the current wish to arm: the
    /// counter counts occasions, not minutes.
    public mutating func noteBusy() -> Bool {
        guard !busyCounted else { return false }
        busyCounted = true
        return true
    }

    /// Someone clicked the update action. A click needs no policy and no
    /// spacing: they asked.
    public mutating func clicked(sessionInProgress: Bool) -> Click {
        switch phase {
        case .idle, .installing, .arming(_, .requested):
            return .nothing
        case .held:
            return .installHeld
        case .arming(let p, .policy):
            // Already downloading: install the moment it is handed over.
            phase = .arming(p, .requested)
            return .nothing
        case .available:
            if sessionInProgress {
                clickWaiting = true
                return .waiting
            }
            return .arm
        }
    }
}

/// Where `UpdateSchedule` keeps what outlives a launch: the pending update,
/// the last arm attempt, and the build an armed install left from.
public enum UpdateScheduleStore {
    public static let pendingKey = "pacer.update.pending"
    public static let lastAttemptKey = "pacer.update.lastArmAttempt"
    /// Set when an armed hold's block is called; the next launch counts
    /// `update.arm.installed` if it runs another build.
    public static let armedInstallFromKey = "pacer.update.armedInstallFrom"

    public static func load(_ store: UserDefaults) -> (pending: UpdateSchedule.Pending?, lastAttempt: Date?) {
        let pending = store.data(forKey: pendingKey).flatMap { try? JSONDecoder().decode(UpdateSchedule.Pending.self, from: $0) }
        return (pending, store.object(forKey: lastAttemptKey) as? Date)
    }

    public static func save(_ schedule: UpdateSchedule, _ store: UserDefaults) {
        if let pending = schedule.pending, let data = try? JSONEncoder().encode(pending) {
            store.set(data, forKey: pendingKey)
        } else {
            store.removeObject(forKey: pendingKey)
        }
        if let lastAttempt = schedule.lastAttempt {
            store.set(lastAttempt, forKey: lastAttemptKey)
        } else {
            store.removeObject(forKey: lastAttemptKey)
        }
    }

    public static func noteArmedInstall(fromBuild build: String, _ store: UserDefaults) {
        store.set(build, forKey: armedInstallFromKey)
    }

    /// True once, at the first launch of a build other than the one an armed
    /// install was started from. The mark is cleared either way.
    public static func takeArmedInstall(currentBuild: String, _ store: UserDefaults) -> Bool {
        guard let from = store.string(forKey: armedInstallFromKey) else { return false }
        store.removeObject(forKey: armedInstallFromKey)
        return from != currentBuild
    }
}
