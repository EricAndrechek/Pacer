import Foundation
import Testing
@testable import PacerCore

/// `SecurityCLI.run` against a fake `security`: `/bin/sh` running a script, so
/// nothing here touches a keychain. What matters is the pipe handling: a pipe
/// holds 64 KB, and output past that used to block the child until the
/// timeout, which then read as `.accessDenied` (#413).
@Suite("SecurityCLI subprocess")
struct SecurityCLITests {

    private static let shell = URL(fileURLWithPath: "/bin/sh")

    private static func run(_ script: String, timeout: TimeInterval = 5) -> (Result<Data, SecurityCLI.Failure>, TimeInterval) {
        let start = Date()
        let result = SecurityCLI.run(["-c", script], executable: shell, timeout: timeout)
        return (result, Date().timeIntervalSince(start))
    }

    /// Well past the 64 KB a pipe buffers, so the child can only finish if
    /// the parent reads while it runs.
    static let bigOutput = 300_000

    @Test("stdout bigger than a pipe arrives whole, without waiting out the timeout")
    func largeStdout() throws {
        let (result, elapsed) = Self.run("head -c \(Self.bigOutput) /dev/zero", timeout: 10)
        let data = try result.get()
        #expect(data.count == Self.bigOutput)
        #expect(elapsed < 5, "took \(elapsed) s: the child blocked on a full pipe")
    }

    @Test("stderr bigger than a pipe does not stall the exit status")
    func largeStderr() {
        let (result, elapsed) = Self.run("head -c \(Self.bigOutput) /dev/zero >&2; exit 44", timeout: 10)
        #expect(result == .failure(.notFound))
        #expect(elapsed < 5, "took \(elapsed) s: the child blocked on a full pipe")
    }

    @Test("both pipes over capacity at once")
    func bothLarge() throws {
        let (result, elapsed) = Self.run(
            "head -c \(Self.bigOutput) /dev/zero >&2; head -c \(Self.bigOutput) /dev/zero", timeout: 10)
        #expect(try result.get().count == Self.bigOutput)
        #expect(elapsed < 5, "took \(elapsed) s")
    }

    @Test("a child that never exits is stopped at the timeout and reads as denied")
    func timeout() {
        // `exec`, so the shell itself is what `terminate()` signals.
        let (result, elapsed) = Self.run("exec sleep 30", timeout: 0.5)
        #expect(result == .failure(.accessDenied))
        #expect(elapsed < 5, "took \(elapsed) s")
    }

    @Test("exit statuses map as before")
    func statuses() throws {
        #expect(try Self.run("printf secret").0.get() == Data("secret".utf8))
        #expect(Self.run("exit 44").0 == .failure(.notFound))
        for status in [36, 51, 128] {
            #expect(Self.run("exit \(status)").0 == .failure(.accessDenied))
        }
        #expect(Self.run("exit 7").0 == .failure(.status(7)))
    }

    /// The drains used to be blocks on `DispatchQueue.global`. With that pool
    /// at its thread limit, as the parallel test suite held it for minutes,
    /// neither started before the deadline and a healthy read reported
    /// `.accessDenied`. Each drain now has a thread of its own.
    @Test("reads while GCD's global pool has no thread to spare")
    func saturatedGlobalPool() throws {
        // Far more blocked work than GCD will give threads to (64 at most for
        // the global queues), so nothing else queued there runs until the
        // `defer` lets it go. Held for a fraction of a second.
        let parked = 512
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        for _ in 0..<parked {
            DispatchQueue.global(qos: .userInitiated).async {
                started.signal()
                release.wait()
            }
        }
        defer { for _ in 0..<parked { release.signal() } }
        // Until the pool stops taking more.
        while started.wait(timeout: .now() + 0.1) == .success {}
        let probe = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { probe.signal() }
        #expect(probe.wait(timeout: .now() + 0.05) == .timedOut,
                "the global pool still had a thread free, so this proves nothing")

        let (result, elapsed) = Self.run("printf secret", timeout: 2)
        #expect(try result.get() == Data("secret".utf8))
        #expect(elapsed < 2, "took \(elapsed) s")
    }

    @Test("a binary that cannot be launched is a spawn failure")
    func spawnFailure() {
        let result = SecurityCLI.run([], executable: URL(fileURLWithPath: "/nonexistent/security"))
        guard case .failure(.spawn) = result else {
            Issue.record("expected .spawn, got \(result)")
            return
        }
    }
}
