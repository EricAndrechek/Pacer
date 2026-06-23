import AppKit
import Darwin
import WidgetKit
import PacerCore

/// One-shot, launch-time guard against a **stale widget extension** left
/// behind when the app bundle is replaced under a running install —
/// Sparkle auto-update or `make install`.
///
/// **Why this is needed.** `PacerWidgets.appex` is a separate process
/// owned by WidgetKit's `chronod`, not a child of the host. When the
/// bundle is swapped, the host quits and relaunches but the extension
/// keeps running its now-deleted old binary. `chronod` neither
/// relaunches the orphan nor services reload requests against the
/// version-mismatched process — it just keeps serving the orphan's
/// frozen timeline, so placed widgets show stale data (and stale layout)
/// until the user reboots.
///
/// Verified empirically 2026-06-23: after a Sparkle update bumped the
/// host to a new build, the extension stayed on its pre-update PID, and
/// a full OAuth-poll → `reloadTimelines` cycle did **not** revive it.
/// Only terminating the process made `chronod` relaunch it from the
/// fresh bundle — at which point its `getTimeline` re-read the shared
/// store and rendered current data. So `reloadTimelines` alone is not a
/// fix; the orphan must actually be killed.
///
/// **What this does.** On launch, if the host's `CFBundleVersion`
/// differs from the build recorded on the previous launch, the bundle
/// was just replaced — terminate any running extension process so
/// `chronod` relaunches it from the current bundle on the next render.
/// The extension is stateless (reads only the shared App Group store),
/// so an unconditional kill is safe.
///
/// Keyed on the build number, this fires exactly once per update and is
/// a no-op on ordinary relaunches and reboots (build unchanged → nothing
/// to do) and on first-ever launch (no prior build → fresh install, the
/// extension is already on this bundle).
///
/// **Limitation.** The *first* update onto a build that contains this
/// guard still orphans, because the pre-update host doing the swap
/// predates the logic. Every update from that build forward is covered.
@MainActor
enum WidgetExtensionRelauncher {

    /// App Group-suite key holding the host build seen on the previous
    /// launch. Lives in the shared suite (not `.standard`) only for
    /// consistency with the rest of Pacer's preferences; nothing else
    /// reads it.
    private static let lastLaunchBuildKey = "pacer.widget.lastLaunchBuild"

    /// The extension's kernel-resident process name (`p_comm`).
    ///
    /// We match on the process NAME, not the executable path, and that
    /// distinction is load-bearing — it's the whole reason the first cut
    /// of this guard shipped broken (v0.3.10). After a bundle swap the
    /// orphaned extension's executable file is unlinked, so
    /// `proc_pidpath` returns 0 and any path-based match silently misses
    /// the exact process this guard exists to kill. `p_comm` lives in the
    /// kernel proc struct and survives the unlink. (Verified 2026-06-23
    /// against a real post-Sparkle orphan: `proc_pidpath` → 0, `proc_name`
    /// → "PacerWidgets".) "PacerWidgets" is 12 chars — within the 15-char
    /// `MAXCOMLEN` limit — and unique to the extension (the host is
    /// "Pacer"), so there's no collision risk.
    private static let extProcessName = "PacerWidgets"

    /// Call once, early in `applicationDidFinishLaunching`.
    static func bounceIfBundleReplaced(
        defaults: UserDefaults = PacerPreferences.store
    ) {
        guard let current = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return }

        let previous = defaults.string(forKey: lastLaunchBuildKey)
        defaults.set(current, forKey: lastLaunchBuildKey)

        // nil  → first-ever launch: fresh install, extension already on
        //        this bundle.
        // ==   → ordinary relaunch or reboot: nothing was swapped.
        // !=   → bundle replaced under the running extension: bounce it.
        guard let previous, previous != current else { return }

        let pids = runningWidgetExtensionPIDs()
        for pid in pids {
            kill(pid, SIGTERM)
        }
        Log.write(
            "WidgetExtensionRelauncher",
            "build \(previous)→\(current): terminated \(pids.count) stale extension process(es)"
        )
        // Prompt an immediate re-render from the relaunched extension so
        // the user isn't left waiting for the next natural timeline
        // request. Harmless if no widgets are placed.
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// PIDs of every running process whose executable is our widget
    /// extension. Uses `libproc` rather than shelling out so there's no
    /// subprocess and no pattern-matching ambiguity. `proc_pidpath` may
    /// return 0 for processes we can't introspect (other users / system
    /// procs); those are simply skipped.
    private static func runningWidgetExtensionPIDs() -> [pid_t] {
        // NOTE: `proc_listallpids` reports the *number of PIDs*, not a
        // byte count — for both the sizing call (NULL buffer → an
        // estimate) and the fill call. (Its `buffersize` argument is in
        // bytes, but the return value is a count; mixing those up
        // silently truncates the scan and misses processes near the end
        // of the table.) So: treat the estimate as a count, over-
        // allocate generously to avoid truncation under churn, and
        // iterate the whole buffer skipping empty (<= 0) slots — which
        // also makes the scan independent of the return value's unit.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        let capacity = Int(estimate) + 256
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard written > 0 else { return [] }

        var matched: [pid_t] = []
        // 256 is ample for a `p_comm` (capped at MAXCOMLEN, 16).
        var nameBuffer = [CChar](repeating: 0, count: 256)
        for pid in pids where pid > 0 {
            // `proc_name` reads `p_comm` from the kernel — it does NOT
            // touch the on-disk executable, so it still resolves for an
            // orphan whose bundle was replaced (where `proc_pidpath`
            // fails). That's exactly the case that matters here.
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            if String(cString: nameBuffer) == extProcessName {
                matched.append(pid)
            }
        }
        return matched
    }
}
