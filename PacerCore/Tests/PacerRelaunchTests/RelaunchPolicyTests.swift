import Testing
@testable import PacerRelaunch

// Pacer crashed on 2026-11-12 and stayed down for 15 hours (#412). These pin
// when it now relaunches itself, and when it gives up: never in a loop.

@Suite("Crash relaunch policy")
struct RelaunchPolicyTests {

    let t0 = 1_800_000_000.0

    @Test func anOrdinaryLaunchArmsTheFirstDelayAndForgetsEarlierRelaunches() {
        let history = RelaunchPolicy.history(previous: [t0 - 60, t0 - 30], relaunchedAfterCrash: false, now: t0)
        #expect(history.isEmpty)
        #expect(RelaunchPolicy.instruction(history: history, now: t0) == .relaunch(afterSeconds: 10))
    }

    /// A crash at launch, every launch: three relaunches backing off, then
    /// the fourth unexpected exit leaves Pacer closed.
    @Test func relaunchesBackOffThenStop() {
        var history: [Double] = []
        var now = t0
        var instructions: [RelaunchInstruction] = [RelaunchPolicy.instruction(history: history, now: now)]
        for _ in 0..<3 {
            if case .relaunch(let seconds) = instructions.last { now += Double(seconds) + 5 }
            history = RelaunchPolicy.history(previous: history, relaunchedAfterCrash: true, now: now)
            instructions.append(RelaunchPolicy.instruction(history: history, now: now))
        }
        #expect(instructions == [.relaunch(afterSeconds: 10), .relaunch(afterSeconds: 30),
                                 .relaunch(afterSeconds: 120), .stayDown(relaunches: 3)])
        #expect(RelaunchPolicy.maxRelaunches == 3)
    }

    /// A crash an hour is not a loop: every relaunched run is the first in
    /// its window, so the back-off never climbs and Pacer never stays down.
    @Test func relaunchesOutsideTheWindowDoNotCount() {
        var history: [Double] = []
        var now = t0
        #expect(RelaunchPolicy.instruction(history: history, now: now) == .relaunch(afterSeconds: 10))
        for _ in 0..<5 {
            now += 3_600
            history = RelaunchPolicy.history(previous: history, relaunchedAfterCrash: true, now: now)
            #expect(history == [now])
            #expect(RelaunchPolicy.instruction(history: history, now: now) == .relaunch(afterSeconds: 30))
        }
    }

    /// A run that stopped relaunching is protected again once its relaunches
    /// are older than the window (`CrashRelaunch.currentInstruction`).
    @Test func theCapLiftsOnceTheRelaunchesAgeOut() {
        let history = [t0, t0 + 20, t0 + 60]
        let window = RelaunchPolicy.window
        #expect(RelaunchPolicy.instruction(history: history, now: t0 + 61) == .stayDown(relaunches: 3))
        #expect(RelaunchPolicy.instruction(history: history, now: t0 + window) == .relaunch(afterSeconds: 120))
        #expect(RelaunchPolicy.instruction(history: history, now: t0 + 20 + window) == .relaunch(afterSeconds: 30))
        #expect(RelaunchPolicy.instruction(history: history, now: t0 + 60 + window) == .relaunch(afterSeconds: 10))
    }

    /// A clock set back must not hold Pacer down: entries in the future drop.
    @Test func entriesFromTheFutureAreDropped() {
        let history = RelaunchPolicy.history(previous: [t0 + 500, t0 + 900], relaunchedAfterCrash: true, now: t0)
        #expect(history == [t0])
        #expect(RelaunchPolicy.instruction(history: [t0 + 1, t0 + 2, t0 + 3], now: t0) == .relaunch(afterSeconds: 10))
    }
}

@Suite("Crash relaunch instructions")
struct RelaunchInstructionTests {

    @Test func everyInstructionSurvivesTheWire() {
        for instruction in [RelaunchInstruction.relaunch(afterSeconds: 10), .stayDown(relaunches: 3), .quit] {
            let line = instruction.line
            #expect(line.hasSuffix("\n"))
            #expect(RelaunchInstruction(line: line.dropLast()) == instruction)
        }
    }

    @Test func anythingElseIsIgnored() {
        for line in ["", "quit now", "relaunch", "relaunch -1", "relaunch 99999", "relaunch ten",
                     "stay-down", "stay-down -2", "reboot", "QUIT"] {
            #expect(RelaunchInstruction(line: line) == nil, "\(line)")
        }
    }

    /// The question the relauncher answers at end-of-file: was this exit
    /// abnormal? Only if Pacer did not say `quit` first.
    @Test func anExitWithoutQuitActsOnTheLastInstruction() {
        var watch = RelaunchWatch()
        watch.receive(Array("relaunch 10\nrelaunch 30\n".utf8))
        #expect(watch.verdict == .relaunch(afterSeconds: 30))
        watch.receive(Array("stay-down 3\n".utf8))
        #expect(watch.verdict == .stayDown(relaunches: 3))
        watch.receive(Array("relaunch 10\n".utf8))
        #expect(watch.verdict == .relaunch(afterSeconds: 10))
    }

    @Test func quitIsFinal() {
        var watch = RelaunchWatch()
        watch.receive(Array("relaunch 10\nquit\nrelaunch 30\n".utf8))
        #expect(watch.quitting)
        #expect(watch.verdict == .nothing)
    }

    @Test func silenceMeansNothingToDo() {
        #expect(RelaunchWatch().verdict == .nothing)
    }

    @Test func linesSplitAcrossReadsStillCount() {
        var watch = RelaunchWatch()
        for chunk in ["rel", "aunch 3", "0\nqu", "it", "\n"] { watch.receive(Array(chunk.utf8)) }
        #expect(watch.quitting)
    }

    /// Pacer writes each line in one write, which a pipe delivers whole, so a
    /// fragment at end-of-file is not something Pacer said: a crash in the
    /// middle of quitting still relaunches.
    @Test func aFragmentAtEndOfFileIsNotAQuit() {
        var watch = RelaunchWatch()
        watch.receive(Array("relaunch 10\nqui".utf8))
        #expect(!watch.quitting)
        #expect(watch.verdict == .relaunch(afterSeconds: 10))
    }

    @Test func anOverlongLineIsDropped() {
        var watch = RelaunchWatch()
        watch.receive(Array(("relaunch 10\n" + String(repeating: "x", count: 200) + "quit\n").utf8))
        #expect(!watch.quitting)
        #expect(watch.verdict == .relaunch(afterSeconds: 10))
    }
}

@Suite("Relauncher arguments")
struct RelauncherArgumentsTests {

    @Test func roundTrip() {
        let arguments = RelauncherArguments(watchedPID: 4242, processName: "Pacer",
                                            command: ["/usr/bin/open", "-n", "-a", "/Applications/Pacer.app"])
        #expect(RelauncherArguments(arguments.arguments) == arguments)
    }

    @Test func unusableArgumentsAreRefused() {
        #expect(RelauncherArguments([]) == nil)
        #expect(RelauncherArguments(["4242", "Pacer"]) == nil)
        #expect(RelauncherArguments(["x", "Pacer", "/usr/bin/open"]) == nil)
        #expect(RelauncherArguments(["1", "Pacer", "/usr/bin/open"]) == nil)
        #expect(RelauncherArguments(["4242", "", "/usr/bin/open"]) == nil)
        #expect(RelauncherArguments(["4242", "Pacer", "open"]) == nil)
    }
}
