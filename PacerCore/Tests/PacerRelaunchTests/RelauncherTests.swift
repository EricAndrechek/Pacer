import Darwin
import Foundation
import Testing
@testable import PacerRelaunch

/// The relauncher end to end, over a real pipe: what it reads, waits for,
/// checks and runs. Nothing is launched; the effects are recorded.
@Suite("Relauncher run")
struct RelauncherRunTests {

    final class Machine {
        var alive: [Bool] = []          // processAlive answers, in order; then false
        var otherInstance: Int32?
        var runStatus: Int32 = 0
        var slept: [Double] = []
        var ran: [[String]] = []
        var logged: [String] = []

        var effects: Relauncher.Effects {
            Relauncher.Effects(
                processAlive: { _ in self.alive.isEmpty ? false : self.alive.removeFirst() },
                runningInstance: { _, _ in self.otherInstance },
                sleep: { self.slept.append($0) },
                run: { self.ran.append($0); return self.runStatus },
                log: { self.logged.append($0) })
        }
    }

    let arguments = RelauncherArguments(watchedPID: 4242, processName: "Pacer",
                                        command: ["/usr/bin/true", "relaunch-me"])

    /// What Pacer wrote before its end closed.
    func run(_ said: String, on machine: Machine) -> Relauncher.Outcome {
        var ends: [Int32] = [-1, -1]
        precondition(pipe(&ends) == 0)
        _ = Array(said.utf8).withUnsafeBytes { write(ends[1], $0.baseAddress, $0.count) }
        close(ends[1])   // Pacer's process ending
        defer { close(ends[0]) }
        return Relauncher.run(arguments, input: ends[0], effects: machine.effects)
    }

    @Test func aQuitNeverRelaunches() {
        let machine = Machine()
        #expect(run("relaunch 10\nquit\n", on: machine) == .quit)
        #expect(machine.ran.isEmpty && machine.slept.isEmpty && machine.logged.isEmpty)
    }

    @Test func anExitWithoutQuitRelaunchesAfterTheDelay() {
        let machine = Machine()
        machine.alive = [true, true]    // still exiting for two polls
        #expect(run("relaunch 30\n", on: machine) == .relaunched)
        #expect(machine.slept == [0.1, 0.1, 30])
        #expect(machine.ran == [["/usr/bin/true", "relaunch-me"]])
        #expect(machine.logged.first == "Pacer (pid 4242) exited without quitting; relaunching in 30 s")
    }

    @Test func aCrashLoopStaysDownAndSaysSo() {
        let machine = Machine()
        #expect(run("stay-down 3\n", on: machine) == .stayedDown(relaunches: 3))
        #expect(machine.ran.isEmpty)
        #expect(machine.logged.count == 1)
        #expect(machine.logged[0].contains("not relaunching: 3 relaunches in the last 30 min"))
    }

    @Test func neverASecondInstance() {
        let machine = Machine()
        machine.otherInstance = 777
        #expect(run("relaunch 10\n", on: machine) == .alreadyRunning(pid: 777))
        #expect(machine.ran.isEmpty)
    }

    @Test func aProcessThatDoesNotGoAwayIsNotRelaunched() {
        let machine = Machine()
        machine.alive = Array(repeating: true, count: 1_000)
        #expect(run("relaunch 10\n", on: machine) == .stillRunning)
        #expect(machine.ran.isEmpty)
        #expect(machine.slept.allSatisfy { $0 == 0.1 })
    }

    @Test func aFailedLaunchIsLogged() {
        let machine = Machine()
        machine.runStatus = 1
        #expect(run("relaunch 10\n", on: machine) == .launchFailed(status: 1))
        #expect(machine.logged.last == "relaunching Pacer failed: /usr/bin/true exited with 1")
    }

    @Test func silenceDoesNothing() {
        let machine = Machine()
        #expect(run("", on: machine) == .quit)
        #expect(machine.ran.isEmpty)
    }

    @Test func theLiveRunnerReportsExitStatusAndSignals() {
        #expect(RelaunchProcess.runToCompletion(["/usr/bin/true"]) == 0)
        #expect(RelaunchProcess.runToCompletion(["/usr/bin/false"]) == 1)
        #expect(RelaunchProcess.runToCompletion(["/bin/sh", "-c", "kill -9 $$"]) == 128 + 9)
        #expect(RelaunchProcess.runToCompletion(["/nonexistent/tool"]) == -1)
    }

    @Test func runningInstancesAreFoundByName() {
        // This test process is excluded by design; a /bin/sleep we start is not.
        var pid: pid_t = 0
        let started = ["/bin/sleep", "5"].withCStringArray { posix_spawn(&pid, "/bin/sleep", nil, nil, $0, environ) }
        #expect(started == 0)
        defer { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        #expect(RelaunchProcess.running(named: "sleep", excluding: 0) != nil)
        #expect(RelaunchProcess.running(named: "no-such-process-\(getpid())", excluding: 0) == nil)
    }

    @Test func logLinesMatchPacersFormat() {
        let line = RelaunchLog.line("relaunched Pacer", at: timespec(tv_sec: 1_778_118_133, tv_nsec: 482_123_456))
        #expect(line == "2026-05-07T01:42:13.482Z [Relauncher] relaunched Pacer\n")
    }
}

/// Starting the relauncher: the pipe plumbing that makes end-of-file mean
/// "Pacer is gone".
@Suite("Relauncher spawn")
struct RelaunchSpawnTests {

    func waitForExit(_ pid: pid_t, timeout: Double = 5) -> Bool {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { return true }
            usleep(20_000)
        }
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
        return false
    }

    /// The child reads the initial instruction and what follows, sees
    /// end-of-file as soon as this process closes its end (so it holds no
    /// copy of the write end itself), and runs in a session of its own, out
    /// of reach of a kill aimed at Pacer's process group.
    @Test func theChildReadsUntilOurEndClosesInItsOwnSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("stdin.txt").path

        let started = try RelaunchProcess.start(
            executable: "/bin/sh", arguments: ["-c", "cat > '\(out)'; echo EOF >> '\(out)'"],
            initial: .relaunch(afterSeconds: 10)).get()
        #expect(getsid(started.pid) == started.pid)
        #expect(getpgid(started.pid) == started.pid)
        #expect(RelaunchProcess.send(.quit, to: started.input))
        close(started.input)

        #expect(waitForExit(started.pid), "the child never saw end-of-file")
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "relaunch 10\nquit\nEOF\n")
    }

    /// The relauncher gone (killed by `bin/dev-quit-app.sh`), Pacer's next
    /// write must fail quietly: a SIGPIPE would kill Pacer as it quits, and
    /// Sentry would report it as a crash.
    @Test func writingAfterTheRelauncherIsGoneFailsQuietly() throws {
        let started = try RelaunchProcess.start(executable: "/usr/bin/true", arguments: [],
                                                initial: .relaunch(afterSeconds: 10)).get()
        #expect(waitForExit(started.pid))
        #expect(!RelaunchProcess.send(.quit, to: started.input))
        close(started.input)
    }

    @Test func aMissingExecutableIsAFailureNotACrash() {
        let result = RelaunchProcess.start(executable: "/nonexistent/PacerRelauncher", arguments: [],
                                           initial: .quit)
        guard case .failure(.spawn) = result else {
            Issue.record("expected a spawn failure, got \(result)")
            return
        }
    }
}

extension Array where Element == String {
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers = map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
