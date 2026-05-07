import Foundation
import Testing
@testable import PacerCore

/// `SelfResourceProbe` is intentionally a thin wrapper around
/// `proc_pidinfo(getpid(), ...)` — the integration *with the kernel*
/// is what we want to lock down. The CPU% helper is a pure function
/// over two snapshots; round-trip the JSON encoding alongside it.
struct SelfResourceProbeTests {

    @Test func captureReturnsPlausibleSelfStats() {
        // Allocate something modest so RSS is at least non-trivial.
        var ballast = [UInt8](repeating: 0xAB, count: 64 * 1024)
        ballast[0] = 0x01

        let snap = SelfResourceProbe.capture()
        #expect(snap != nil)
        guard let snap else { return }

        // PID matches our own process — the whole point of using
        // proc_pidinfo with getpid() is to avoid asking about other
        // processes (which would trigger TCC on Sequoia).
        #expect(snap.pid == getpid())

        // RSS for any running test runner is comfortably above 1 MB.
        // 100 KB is a deliberately loose floor that won't false-fail
        // on a stripped-down CI host.
        #expect(snap.rssBytes > 100_000)

        // CPU time is monotonic non-negative, may be near-zero on a
        // freshly-launched test process — exact-zero is acceptable.
        #expect(snap.cpuTotalSeconds >= 0)

        // Reference the ballast so the optimizer doesn't strip it.
        #expect(ballast[0] == 0x01)
    }

    @Test func cpuPercentComputesDeltaOverInterval() {
        let t0 = Date()
        let prev = SelfResourceProbe.Snapshot(
            pid: 1234,
            rssBytes: 0,
            cpuTotalSeconds: 1.0,
            timestamp: t0
        )
        let curr = SelfResourceProbe.Snapshot(
            pid: 1234,
            rssBytes: 0,
            cpuTotalSeconds: 1.5,
            timestamp: t0.addingTimeInterval(2.0)
        )
        // 0.5 CPU-seconds spent over 2.0 wall seconds → 25% of one core.
        let pct = SelfResourceProbe.cpuPercent(from: prev, to: curr)
        #expect(pct != nil)
        if let pct {
            #expect(abs(pct - 25.0) < 0.001)
        }
    }

    @Test func cpuPercentRejectsNonPositiveInterval() {
        let t = Date()
        let snap = SelfResourceProbe.Snapshot(pid: 1, rssBytes: 0, cpuTotalSeconds: 0, timestamp: t)
        #expect(SelfResourceProbe.cpuPercent(from: snap, to: snap) == nil)

        let earlier = SelfResourceProbe.Snapshot(
            pid: 1, rssBytes: 0, cpuTotalSeconds: 0,
            timestamp: t.addingTimeInterval(1)
        )
        // Going "backwards" in time → no result rather than negative %.
        #expect(SelfResourceProbe.cpuPercent(from: earlier, to: snap) == nil)
    }

    @Test func daemonStatsRoundTripsThroughJSON() throws {
        let original = DaemonStats(
            pid: 4242,
            rssBytes: 12_345_678,
            cpuPercent: 3.14,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try original.encoded()
        // Sanity: JSON object syntax + ISO date string with timezone.
        #expect(encoded.hasPrefix("{"))
        #expect(encoded.contains("\"pid\":4242"))

        let decoded = DaemonStats.decode(from: encoded)
        #expect(decoded == original)
    }

    @Test func daemonStatsTolerantOfMalformedJSON() {
        #expect(DaemonStats.decode(from: "not json") == nil)
        #expect(DaemonStats.decode(from: "") == nil)
        #expect(DaemonStats.decode(from: "{\"pid\":1}") == nil)  // missing required fields
    }
}
