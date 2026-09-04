import Foundation
import PacerCore

/// Logs when the main thread stops servicing its run loop for longer than a
/// frame budget allows.
///
/// Added because "switching accounts takes about five seconds" could not be
/// explained by anything measurable: the pace chart's own load was 578 ms and
/// already off the main actor, and every other query on the dashboard reads a
/// table of a few hundred rows. Guessing produced three plausible culprits and
/// no evidence. This produces evidence — a timestamped duration for every main
/// thread stall, so a slow interaction says how long it blocked and when.
///
/// Cheap enough to leave on: one timer at 10 Hz that compares "now" against
/// when it last ran, and writes a line only when the gap is anomalous.
@MainActor
final class MainThreadStallWatchdog {
    static let shared = MainThreadStallWatchdog()

    /// Roughly six frames at 60 Hz. Below this a stall is invisible; above it
    /// the user sees the window stop responding.
    private static let threshold: TimeInterval = 0.1
    private static let tick: TimeInterval = 0.05

    private var timer: Timer?
    private var lastFired = Date()

    private init() {}

    func start() {
        guard timer == nil else { return }
        lastFired = Date()
        let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let gap = now.timeIntervalSince(self.lastFired) - Self.tick
                self.lastFired = now
                if gap >= Self.threshold {
                    Log.write("MainThread", "stalled \(Int(gap * 1000))ms")
                }
            }
        }
        // `.common` so the stall is still reported while a menu is open or the
        // window is being resized — which is exactly when the account switch
        // this was written for happens.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
