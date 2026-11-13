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
/// Sparkle delivers "you're up to date" through the error channel
/// (`SUNoUpdateError`), so that code is mapped to its own outcome rather than
/// recorded as a failure.
///
/// Sparkle calls every method here on the main thread (`SPUUpdater` is
/// main-thread only), which is what the `assumeIsolated` calls rely on.
private class PacerUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        UpdateOutcomeLog.record(.found, version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        UpdateOutcomeLog.record(.noUpdate)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        // Domain and code only (and the underlying error's): never the description.
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        UpdateOutcomeLog.record(.downloadFailed, version: item.displayVersionString,
                                error: UpdateOutcomeLog.errorDetail(domain: ns.domain, code: ns.code,
                                                                    underlyingDomain: underlying?.domain,
                                                                    underlyingCode: underlying?.code))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let byPolicy = MainActor.assumeIsolated { UpdateInstallScheduler.shared.installingByPolicy }
        // `item` is the one being installed: after a failed delta Sparkle swaps
        // in the full-DMG item before this fires (`fallBackAndDownloadRegularUpdate`),
        // so a fallback reads `false` here, which is the point.
        UpdateOutcomeLog.record(byPolicy ? .idleInstall : .willInstall, version: item.displayVersionString,
                                delta: item.isDeltaUpdate)
    }

    // Returning true keeps the automatic driver, and so Sparkle's session,
    // alive until the block runs: no check can resume this update or find
    // another behind it meanwhile (`UpdateInstallScheduler` has the source
    // walk-through). Sparkle still installs on quit if Pacer quits first.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        // This item is the one the automatic driver was handed; a later
        // `willInstallUpdate` carries the one actually installed and overwrites.
        let delta = item.isDeltaUpdate
        let held = MainActor.assumeIsolated {
            UpdateInstallScheduler.shared.hold(version: version, updater: updater, install: immediateInstallHandler)
        }
        if held { UpdateOutcomeLog.record(.readyToInstall, version: version, delta: delta) }
        return held
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { UpdateInstallScheduler.shared.noteRelaunching() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        MainActor.assumeIsolated { UpdateInstallScheduler.shared.release() }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // A held update's cycle only ends when its driver is gone, and the
        // block with it.
        MainActor.assumeIsolated { UpdateInstallScheduler.shared.release() }
        guard let error else { return }
        let ns = error as NSError
        if ns.domain == UpdateOutcomeLog.sparkleErrorDomain, ns.code == UpdateOutcomeLog.sparkleNoUpdateCode {
            UpdateOutcomeLog.record(.noUpdate, endOfCycle: true)
        } else {
            UpdateOutcomeLog.record(UpdateOutcomeLog.result(forErrorDomain: ns.domain, code: ns.code),
                                    endOfCycle: true)
        }
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
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // `.updatesInBackground` is the launch/scheduled check;
        // `.updates` is the user clicking "Check for Updates…".
        if updateCheck == .updatesInBackground {
            throw NSError(
                domain: "com.ericandrechek.pacer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Automatic update checks are disabled in Debug builds."]
            )
        }
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
/// that update instead, as "Relaunch to Update".
struct CheckForUpdatesView: View {
    @ObservedObject private var checker: UpdaterChecker

    init(updater: SPUUpdater) {
        self.checker = UpdaterChecker(updater: updater)
    }

    var body: some View {
        // Read here, in this body, so the title follows the hold.
        let waiting = UpdateInstallScheduler.shared.readyVersion != nil
        Button(waiting ? "Relaunch to Update" : "Check for Updates…") {
            // Decided at the click, not from the render: the hold can end
            // between the two.
            if UpdateInstallScheduler.shared.readyVersion != nil {
                UpdateInstallScheduler.shared.installNow()
            } else {
                checker.updater.checkForUpdates()
            }
        }
        .disabled(!waiting && !checker.canCheckForUpdates)
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
