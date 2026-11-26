import AppKit
import Observation
import PacerCore

/// Where Pacer's own update stands, for every surface that shows it: the
/// sidebar footer, the status menu, the app menu's update item.
///
/// Two inputs, each with one owner:
/// - **the check's progress** (`phase`), from Sparkle's delegate callbacks
///   (`PacerUpdaterDelegate`, which Sparkle calls on the main thread), through
///   `UpdateState.applying(_:)`;
/// - **a pending or ready update**, which is `UpdateInstallScheduler`'s
///   schedule: an update a check found and left on the server (#470), or its
///   hold of Sparkle's install block (`readyVersion`). Read, not copied:
///   "ready" and "the block that installs it" cannot disagree.
///
/// Both are observable, so a view whose body reads `state` follows either.
@MainActor @Observable
final class UpdateStatus {

    static let shared = UpdateStatus()

    /// This build's version, as every surface labels it. The README
    /// screenshot run shows a pinned one (`ScreenshotMode.pinnedVersion`); a
    /// live render shows the real one, since it shows what the user sees.
    let version: AppVersionLabel

    private(set) var phase: UpdateState = .upToDate

    /// A diagnostic render's forced state (`PACER_RENDER_UPDATE_STATE`, set
    /// only by `LiveRenderMode`), so every state can be drawn without an
    /// update to find.
    var forced: UpdateState?

    private init() {
        version = ScreenshotMode.isActive && !LiveRenderMode.isActive
            ? ScreenshotMode.pinnedVersion
            : Self.currentVersion
    }

    var state: UpdateState {
        if let forced { return forced }
        let scheduler = UpdateInstallScheduler.shared
        return UpdateState.resolve(phase: phase, heldVersion: scheduler.readyVersion,
                                   installing: scheduler.isInstalling,
                                   availableVersion: scheduler.offeredVersion)
    }

    func note(_ event: UpdateState.Event) {
        let next = phase.applying(event)
        guard next != phase else { return }
        phase = next
    }

    /// Install the update now and relaunch into it: the held one, or a pending
    /// one once it is downloaded. An explicit click, so `UpdateInstallPolicy`
    /// does not apply: its never-interrupt rules (an open menu, text being
    /// edited) guard against a relaunch nobody asked for, and this one was
    /// asked for (`UpdateInstallScheduler.installNow`). Bypassing the editing
    /// guard is deliberate. Decided at the click: with nothing offered, or an
    /// install already started, it does nothing.
    func installNow() {
        UpdateInstallScheduler.shared.installNow()
    }

    nonisolated static var currentVersion: AppVersionLabel {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return AppVersionLabel(info: Bundle.main.infoDictionary ?? [:], isDebugBuild: debug)
    }
}
