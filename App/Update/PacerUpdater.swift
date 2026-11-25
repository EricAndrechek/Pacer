import Foundation
import PacerCore
import Sparkle
import SwiftUI

/// Sparkle 2.x wrapper. `SPUStandardUpdaterController` owns an
/// `SPUUpdater` and a `SPUStandardUserDriver` and handles the on-launch
/// check + 6-hour scheduled checks automatically when `startingUpdater`
/// is true. The wrapper exists so SwiftUI can `@StateObject` it and so
/// the Check-for-Updates menu item can disable while a check is in
/// flight (`canCheckForUpdates` is KVO-observable, which the
/// `CheckForUpdatesView` below adapts to `@Published`).
@MainActor
final class PacerUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController

    // User-driver delegate that supplies a custom version displayer (see
    // PacerUserDriverDelegate). Retained here because `SPUStandardUserDriver`
    // holds its delegate weakly. Applies to every build, not just Debug:
    // it controls the version text in Sparkle's standard update dialogs.
    private let uiDelegate = PacerUserDriverDelegate()

    // The updater delegate in Release: telemetry outcomes plus the
    // install-at-a-quiet-moment hand-off (`UpdateInstallScheduler`). Held
    // strongly for the same reason as the Debug delegate below.
    private let outcomeObserver: PacerUpdaterDelegate

    #if DEBUG
    // Retained for the updater's lifetime — `SPUUpdater` holds its
    // delegate weakly, so without this strong reference the delegate
    // would deallocate immediately and the gate below would never fire.
    private let devDelegate: DevBuildUpdaterDelegate
    #endif

    init() {
        // `startingUpdater: true` schedules the on-launch check + 6h
        // recurrence using the feed URL and interval declared in
        // Info.plist (SUFeedURL, SUScheduledCheckInterval). No extra
        // wiring needed here.
        //
        // `uiDelegate` is a stored property with an inline initializer, so
        // it's set before `init` runs — but Swift still forbids reading
        // `self.uiDelegate` until every stored property (incl. `controller`)
        // is assigned. Capture it in a local to pass into the controller.
        let userDriverDelegate = uiDelegate
        let outcomes = PacerUpdaterDelegate()
        self.outcomeObserver = outcomes
        // Now, not when an update first arrives: the policy needs to know when
        // Pacer was last in use, which it only learns by watching from launch.
        _ = UpdateInstallScheduler.shared
        #if DEBUG
        // Local Debug builds: install a delegate that vetoes automatic
        // (launch + scheduled) update checks. See DevBuildUpdaterDelegate.
        // Construct the delegate as a local first — `self` isn't fully
        // initialized until `controller` is set, so we can't reference
        // `self.devDelegate` while building the controller.
        let delegate = DevBuildUpdaterDelegate()
        self.devDelegate = delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: userDriverDelegate
        )
        #else
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: outcomes,
            userDriverDelegate: userDriverDelegate
        )
        #endif
        scheduleCatchUpCheck()
    }

    /// Just updated (the build differs from the last launch's)? Check again in
    /// a couple of minutes, once: an update held while Pacer ran an older
    /// version may already have a newer one behind it. Only the user's own
    /// launch records the build.
    private func scheduleCatchUpCheck() {
        guard LaunchMode.isNormalLaunch,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        let store = PacerPreferences.store
        let previous = store.string(forKey: UpdateRetryPolicy.lastLaunchBuildKey)
        store.set(build, forKey: UpdateRetryPolicy.lastLaunchBuildKey)
        guard UpdateRetryPolicy.needsCatchUpCheck(previousBuild: previous, currentBuild: build) else { return }
        let updater = controller.updater
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateRetryPolicy.catchUpDelay) {
            // Sparkle does not enforce the user's "check automatically" choice
            // on a call like this one.
            guard updater.automaticallyChecksForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    var updater: SPUUpdater { controller.updater }
}

/// Writes what Sparkle did to `UpdateOutcomeLog`, for the daily check-in, and
/// takes over installing a downloaded update (`willInstallUpdateOnQuit`), which
/// Sparkle would otherwise leave until a quit that a menu-bar agent never does:
/// see `UpdateInstallScheduler`. That hand-off is the one callback here that
/// changes what Sparkle does, besides the Debug-only `mayPerform` veto below.
/// Every build uses it; the Debug delegate subclasses it so both keep
/// reporting. In Debug the hand-off never fires: it comes only from the
/// automatic (background) driver, and the veto stops every background check
/// before it downloads anything.
///
/// It also tells `UpdateStatus` how the check is going, for the surfaces that
/// show it (the sidebar footer, the status menu).
///
/// Sparkle delivers "you're up to date" through the error channel
/// (`SUNoUpdateError`), so that code is mapped to its own outcome rather than
/// recorded as a failure.
///
/// Sparkle calls every method here on the main thread (`SPUUpdater` is
/// main-thread only), which is what the `assumeIsolated` calls rely on.
private class PacerUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Called before every check; one that throws is not made. The Debug
    /// delegate overrides it to veto background checks, and calls this only
    /// for the checks it lets through.
    ///
    /// Sparkle calls this right before every check and reads `httpHeaders`
    /// only afterwards. Setting them here, from scratch each time, makes a
    /// toggle change land on the very next request. Sparkle has already
    /// stamped `lastUpdateCheckDate` with now by this point (SPUUpdater.m),
    /// so "since the last check" comes from Pacer's own previous-check date,
    /// read before it is written. Never throws: it only decorates the request.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // `.updates` is the user's "Check for Updates…"; the launch and
        // scheduled checks (`.updatesInBackground`) and the info-only probe
        // are `scheduled`.
        note(.checkStarted)
        feedLoaded = false
        let last = FeedRequestHeaders.previousCheck(
            key: PacerPreferenceKeys.appcastLastCheck, store: PacerPreferences.store,
            now: Date(), record: LaunchMode.isNormalLaunch)
        // The fallback feed (raw.githubusercontent.com) gets none of them:
        // `X-Pacer-*` reach only pacer.andrechek.com. The chooser's state
        // cannot change between here and the request.
        updater.httpHeaders = feedChooser.usesFallback ? [:] : FeedRequestHeaders.headers(
            check: updateCheck == .updates ? .manual : .scheduled,
            since: last,
            id: FeedRequestIdentity.idHeader())
    }

    /// Which appcast the next check reads: `SUFeedURL` (the site) unless the
    /// check before it could not reach it, then the same file on `main`, once.
    /// Sparkle's own words: "An appcast feed URL to check for new updates in,
    /// or nil for the default behavior" (`feedURLStringForUpdater:`).
    private var feedChooser = FeedFallback.AppcastChooser()

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedChooser.feedURLString
    }

    // Sparkle also puts `httpHeaders` on the update archive and delta
    // downloads and on release-notes fetches, which are not our site (GitHub
    // releases). Nothing X-Pacer-* may reach them, the id least of all.
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        FeedRequestHeaders.strip(request)
        note(.downloadStarted(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        // Notes are inline today; a notes URL elsewhere would get the headers.
        guard let url = updateItem.releaseNotesURL ?? updateItem.fullReleaseNotesURL else { return true }
        return FeedRequestHeaders.isPacerSite(url)
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        feedLoaded = true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        UpdateOutcomeLog.record(.found, version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        UpdateOutcomeLog.record(.noUpdate)
        note(.noUpdate)
    }

    // Extracted is as far as the progress goes: what follows is the hold
    // (`UpdateInstallScheduler`, which `UpdateStatus` reads) or Sparkle's own
    // install prompt.
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        note(.prepared)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        note(.downloadFailed)
        // Domain and code only (and the underlying error's): never the description.
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        UpdateOutcomeLog.record(.downloadFailed, version: item.displayVersionString,
                                error: UpdateOutcomeLog.errorDetail(domain: ns.domain, code: ns.code,
                                                                    underlyingDomain: underlying?.domain,
                                                                    underlyingCode: underlying?.code))
        FeedFallback.reportDownloadFailure(domain: ns.domain, code: ns.code,
                                           underlyingDomain: underlying?.domain, underlyingCode: underlying?.code)
        // Sooner than the 6 h interval, with backoff: 30 min, 2 h, then normal.
        downloadFailures += 1
        if let delay = UpdateRetryPolicy.downloadRetryDelay(afterFailures: downloadFailures) {
            recheck(updater, after: delay)
        }
    }

    /// One extra background check, never when the user turned automatic checks
    /// off (Sparkle does not enforce that on a direct call). If a session is
    /// already running Sparkle ignores it.
    private func recheck(_ updater: SPUUpdater, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak updater] in
            guard let updater, updater.automaticallyChecksForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    /// Set by `didFinishLoadingAppcast`, cleared before every check: what
    /// separates "the feed was unreachable" from "the archive download failed",
    /// which are both `SUDownloadError`.
    private var feedLoaded = false

    /// Failed downloads in a row; a download that gets to install ends the run.
    private var downloadFailures = 0

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        downloadFailures = 0
        let byPolicy = MainActor.assumeIsolated { UpdateInstallScheduler.shared.installingByPolicy }
        // `item` is the one being installed: after a failed delta Sparkle swaps
        // in the full-DMG item before this fires (`fallBackAndDownloadRegularUpdate`),
        // so a fallback reads `false` here, which is the point.
        UpdateOutcomeLog.record(byPolicy ? .idleInstall : .willInstall, version: item.displayVersionString,
                                delta: item.isDeltaUpdate)
        note(.prepared)
    }

    // Returning true keeps the automatic driver, and so Sparkle's session,
    // alive until the block runs: no check can resume this update or find
    // another behind it meanwhile (`UpdateInstallScheduler` has the source
    // walk-through). Sparkle still installs on quit if Pacer quits first.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        downloadFailures = 0
        let version = item.displayVersionString
        // This item is the one the automatic driver was handed; a later
        // `willInstallUpdate` carries the one actually installed and overwrites.
        let delta = item.isDeltaUpdate
        let held = MainActor.assumeIsolated {
            UpdateInstallScheduler.shared.hold(version: version, updater: updater, install: immediateInstallHandler)
        }
        if held { UpdateOutcomeLog.record(.readyToInstall, version: version, delta: delta) }
        note(.prepared)
        return held
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { UpdateInstallScheduler.shared.noteRelaunching() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        MainActor.assumeIsolated { UpdateInstallScheduler.shared.release() }
        let ns = error as NSError
        note(.aborted(noUpdate: UpdateState.isNoUpdate(domain: ns.domain, code: ns.code)))
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // A held update's cycle only ends when its driver is gone, and the
        // block with it.
        MainActor.assumeIsolated { UpdateInstallScheduler.shared.release() }
        let ns = error as NSError?
        let underlying = ns?.userInfo[NSUnderlyingErrorKey] as? NSError
        // "Up to date" arrives as an error too; only a feed that could not be
        // reached counts (see `FeedFallback.appcastFailure`).
        let failure = ns.flatMap { FeedFallback.appcastFailure($0, feedLoaded: feedLoaded) }
        let wasFallback = feedChooser.usesFallback
        if case .report(let primary, let fallbackOK) = feedChooser.finished(failure: failure) {
            FeedFallback.report(feed: .appcast, failure: primary, fallbackOK: fallbackOK)
        }
        // The primary just failed: read the fallback soon, not in ~6 h.
        if !wasFallback, feedChooser.usesFallback { recheck(updater, after: FeedFallback.failoverRecheckDelay) }
        // A check that got through (an answer, even "up to date") ends the backoff.
        if ns == nil || (ns?.domain == "SUSparkleErrorDomain" && ns?.code == 1001) { downloadFailures = 0 }
        let failed = ns.map { !UpdateState.isNoUpdate(domain: $0.domain, code: $0.code) } ?? false
        note(.cycleFinished(failed: failed))
        guard let ns else { return }
        // Domain and code only (and the underlying error's): never the description.
        UpdateOutcomeLog.recordEndOfCycle(domain: ns.domain, code: ns.code,
                                          underlyingDomain: underlying?.domain,
                                          underlyingCode: underlying?.code)
    }

    fileprivate func note(_ event: UpdateState.Event) {
        MainActor.assumeIsolated { UpdateStatus.shared.note(event) }
    }
}

/// Controls the version text Sparkle prints in its standard update
/// dialogs ("…is now available—you have…", "…is currently the newest
/// version available").
///
/// Sparkle's default `SUVersionDisplay` disambiguates two builds that
/// share a `CFBundleShortVersionString` by appending the differing
/// `CFBundleVersion` in parentheses — which, because Pacer's build
/// number is a unix timestamp, surfaced as e.g. "Pacer 0.1.1
/// (1780503333)". (It only appears when the marketing versions collide,
/// i.e. a dev build checking against a same-version release; a normal
/// 0.1.1 → 0.2.0 update never triggers it. But it's ugly when it shows.)
///
/// Returning the marketing version unchanged from
/// `formatBundleDisplayVersion(…)` suppresses the appended build number;
/// leaving the update-side formatter unimplemented makes Sparkle fall
/// back to the appcast's plain `sparkle:shortVersionString` there too.
/// This mirrors the About window, which also shows only the marketing
/// version (with the build on hover).
private final class PacerUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate, SUVersionDisplay {
    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        self
    }

    // Required by SUVersionDisplay. Used for the "…is now available—you
    // have…" alert. Return the update's marketing version and leave the
    // bundle's display version (passed in) untouched — so neither side
    // gets the build number appended.
    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion bundleVersion: String
    ) -> String {
        update.displayVersionString
    }

    // Optional. Used for the "…is currently the newest version available"
    // (no-update) message. Return the marketing version unchanged.
    func formatBundleDisplayVersion(
        _ bundleDisplayVersion: String,
        withBundleVersion bundleVersion: String,
        matchingUpdate: SUAppcastItem?
    ) -> String {
        bundleDisplayVersion
    }
}

#if DEBUG
/// Vetoes Sparkle's *automatic* update checks in local Debug builds.
///
/// A dev build's `CFBundleVersion` is stamped with its build timestamp
/// (see bin/dev-install.sh), which keeps a *fresh* build at or above the
/// latest release — but a dev build left running while a newer release
/// ships would still see that release as "newer" on the next scheduled
/// check and offer to install it, silently replacing the locally-built
/// app with the public DMG. Blocking only the background check closes
/// that footgun while leaving the user-initiated "Check for Updates…"
/// item fully functional, so the flow can still be exercised on purpose.
///
/// This denies at runtime rather than flipping `automaticallyChecksForUpdates`,
/// which would persist into the `SUEnableAutomaticChecks` user default and
/// leak into a release build sharing the same bundle identifier.
///
/// Compiled out of Release builds entirely.
private final class DevBuildUpdaterDelegate: PacerUpdaterDelegate {
    override func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // `.updatesInBackground` is the launch/scheduled check;
        // `.updates` is the user clicking "Check for Updates…".
        if updateCheck == .updatesInBackground {
            throw NSError(
                domain: "com.ericandrechek.pacer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Automatic update checks are disabled in Debug builds."]
            )
        }
        // A check that goes ahead shows as one (`UpdateStatus`).
        try super.updater(updater, mayPerform: updateCheck)
    }
}
#endif

/// SwiftUI bridge for the Check-for-Updates menu item. Watches the
/// updater's `canCheckForUpdates` (true except during an active check)
/// and disables the menu item accordingly. Sparkle's recommended
/// SwiftUI integration shape.
///
/// While a downloaded update waits for a quiet moment (`UpdateInstallScheduler`)
/// Sparkle's session stays open and no check can run, so the item installs
/// that update instead, as "Update to 0.9.5 — Restart", the status menu's words
/// (`UpdateCopy`).
struct CheckForUpdatesView: View {
    @ObservedObject private var checker: UpdaterChecker

    init(updater: SPUUpdater) {
        self.checker = UpdaterChecker(updater: updater)
    }

    var body: some View {
        // Read here, in this body, so the title follows the hold.
        let state = UpdateStatus.shared.state
        let ready = state.readyVersion
        Button(ready.map(UpdateCopy.menuInstall) ?? UpdateCopy.checkForUpdates) {
            // Decided at the click, not from the render: the hold can end
            // between the two.
            if UpdateInstallScheduler.shared.readyVersion != nil {
                UpdateStatus.shared.installNow()
            } else {
                checker.updater.checkForUpdates()
            }
        }
        .disabled(state.isInstalling || (ready == nil && !checker.canCheckForUpdates))
    }
}

/// Tiny KVO-to-@Published adapter so the menu item state tracks the
/// updater. Sparkle exposes `canCheckForUpdates` as a KVO-observable
/// property; the @Published mirror is what SwiftUI redraws against.
@MainActor
private final class UpdaterChecker: ObservableObject {
    let updater: SPUUpdater
    @Published var canCheckForUpdates: Bool

    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        self.updater = updater
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                self?.canCheckForUpdates = newValue
            }
        }
    }
}
