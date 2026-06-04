import Foundation
import Sparkle
import SwiftUI

/// Sparkle 2.x wrapper. `SPUStandardUpdaterController` owns an
/// `SPUUpdater` and a `SPUStandardUserDriver` and handles the on-launch
/// check + 24-hour scheduled checks automatically when `startingUpdater`
/// is true. The wrapper exists so SwiftUI can `@StateObject` it and so
/// the Check-for-Updates menu item can disable while a check is in
/// flight (`canCheckForUpdates` is KVO-observable, which the
/// `CheckForUpdatesView` below adapts to `@Published`).
@MainActor
final class PacerUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController

    #if DEBUG
    // Retained for the updater's lifetime — `SPUUpdater` holds its
    // delegate weakly, so without this strong reference the delegate
    // would deallocate immediately and the gate below would never fire.
    private let devDelegate: DevBuildUpdaterDelegate
    #endif

    init() {
        // `startingUpdater: true` schedules the on-launch check + 24h
        // recurrence using the feed URL and interval declared in
        // Info.plist (SUFeedURL, SUScheduledCheckInterval). No extra
        // wiring needed here.
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
            userDriverDelegate: nil
        )
        #else
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

    var updater: SPUUpdater { controller.updater }
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
private final class DevBuildUpdaterDelegate: NSObject, SPUUpdaterDelegate {
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
struct CheckForUpdatesView: View {
    @ObservedObject private var checker: UpdaterChecker

    init(updater: SPUUpdater) {
        self.checker = UpdaterChecker(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            checker.updater.checkForUpdates()
        }
        .disabled(!checker.canCheckForUpdates)
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
