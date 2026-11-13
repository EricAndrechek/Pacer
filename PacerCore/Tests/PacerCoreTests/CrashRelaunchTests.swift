import Foundation
import PacerRelaunch
import Testing
@testable import PacerCore

/// What each launch arms and what it leaves for telemetry (#412), against an
/// isolated defaults suite. The policy itself is in PacerRelaunchTests.
@Suite("Crash relaunch launch plan")
struct CrashRelaunchTests {

    func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        // `pacer.testprocess.*` so `make test` sweeps the plist cfprefsd writes back.
        let name = "pacer.testprocess.crashRelaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func counts(_ defaults: UserDefaults) -> [String: Int] {
        var out: [String: Int] = [:]
        CrashRelaunch.moveCountsToTelemetry(defaults: defaults) { out[$0, default: 0] += $1 }
        return out
    }

    @Test func aCrashLoopRelaunchesThreeTimesThenGivesUpAndCountsBoth() {
        withDefaults { defaults in
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let first = CrashRelaunch.planLaunch(relaunchedAfterCrash: false, now: t0, defaults: defaults)
            #expect(first == .init(instruction: .relaunch(afterSeconds: 10), relaunched: false, recentRelaunches: 0))

            var plans: [CrashRelaunch.LaunchPlan] = []
            for step in 1...3 {
                plans.append(CrashRelaunch.planLaunch(relaunchedAfterCrash: true,
                                                      now: t0.addingTimeInterval(Double(step) * 60), defaults: defaults))
            }
            #expect(plans.map(\.instruction) == [.relaunch(afterSeconds: 30), .relaunch(afterSeconds: 120),
                                                 .stayDown(relaunches: 3)])
            #expect(plans.map(\.recentRelaunches) == [1, 2, 3])
            #expect(counts(defaults) == [CrashRelaunch.relaunchedCounter: 3, CrashRelaunch.gaveUpCounter: 1])
            // Reported once.
            #expect(counts(defaults).isEmpty)
        }
    }

    /// Opened by hand (or by the login item, or by Sparkle after an update):
    /// protected again from the first delay.
    @Test func anyOtherLaunchStartsOver() {
        withDefaults { defaults in
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            for step in 0..<3 {
                _ = CrashRelaunch.planLaunch(relaunchedAfterCrash: true, now: t0.addingTimeInterval(Double(step)),
                                             defaults: defaults)
            }
            let manual = CrashRelaunch.planLaunch(relaunchedAfterCrash: false, now: t0.addingTimeInterval(10),
                                                  defaults: defaults)
            #expect(manual.instruction == .relaunch(afterSeconds: 10))
            #expect(CrashRelaunch.currentInstruction(now: t0.addingTimeInterval(11), defaults: defaults)
                    == .relaunch(afterSeconds: 10))
        }
    }

    /// The run that gave up re-arms once it has been up for the window.
    @Test func aRunThatGaveUpIsProtectedAgainAfterTheWindow() {
        withDefaults { defaults in
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            for step in 0..<3 {
                _ = CrashRelaunch.planLaunch(relaunchedAfterCrash: true, now: t0.addingTimeInterval(Double(step)),
                                             defaults: defaults)
            }
            #expect(CrashRelaunch.currentInstruction(now: t0.addingTimeInterval(60), defaults: defaults)
                    == .stayDown(relaunches: 3))
            #expect(CrashRelaunch.currentInstruction(now: t0.addingTimeInterval(RelaunchPolicy.window + 5),
                                                     defaults: defaults) == .relaunch(afterSeconds: 10))
        }
    }

    /// The command the relauncher runs, and what the relaunched app looks for.
    @Test func theRelaunchCommandMarksTheLaunchAndNeverReopensARunningPacer() {
        let command = CrashRelaunch.relaunchCommand(bundlePath: "/Applications/Pacer.app")
        #expect(command.first == "/usr/bin/open")
        #expect(command.contains("-n") && command.contains("-g"))
        #expect(command.contains("\(CrashRelaunch.environmentKey)=1"))
        #expect(command.firstIndex(of: "-a").map { command[$0 + 1] } == "/Applications/Pacer.app")
        let arguments = RelauncherArguments(watchedPID: 4242, processName: "Pacer", command: command)
        #expect(RelauncherArguments(arguments.arguments) == arguments)
    }

    @Test func runsADeveloperIsDrivingAreNotArmed() {
        #expect(CrashRelaunch.skip(disabled: false, debuggerAttached: false, startedFromTerminal: false) == nil)
        #expect(CrashRelaunch.skip(disabled: true, debuggerAttached: true, startedFromTerminal: true) == .turnedOff)
        #expect(CrashRelaunch.skip(disabled: false, debuggerAttached: true, startedFromTerminal: true) == .debugger)
        #expect(CrashRelaunch.skip(disabled: false, debuggerAttached: false, startedFromTerminal: true) == .terminal)
    }

    /// Health counters, so they reach Sentry as metrics too.
    @Test func theCountersAreNotUsageData() {
        for key in [CrashRelaunch.relaunchedCounter, CrashRelaunch.gaveUpCounter, CrashRelaunch.unavailableCounter] {
            #expect(!CounterRouting.isUsage(key))
        }
    }
}
