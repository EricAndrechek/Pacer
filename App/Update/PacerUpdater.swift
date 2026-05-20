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

    init() {
        // `startingUpdater: true` schedules the on-launch check + 24h
        // recurrence using the feed URL and interval declared in
        // Info.plist (SUFeedURL, SUScheduledCheckInterval). No extra
        // wiring needed here.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }
}

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
