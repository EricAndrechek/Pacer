import Foundation
import Testing
@testable import PacerCore

@Suite("Launch origin")
struct LaunchOriginTests {

    @Test("the Apple event marker wins; otherwise a recent boot with the login item on")
    func classify() {
        #expect(LaunchOrigin.classify(appleEventSaysLogin: true, loginItemEnabled: false, secondsSinceBoot: 99_999) == .login)
        #expect(LaunchOrigin.classify(appleEventSaysLogin: false, loginItemEnabled: true, secondsSinceBoot: 60) == .login)
        #expect(LaunchOrigin.classify(appleEventSaysLogin: false, loginItemEnabled: false, secondsSinceBoot: 60) == .manual)
        #expect(LaunchOrigin.classify(appleEventSaysLogin: false, loginItemEnabled: true, secondsSinceBoot: 4_000) == .manual)
    }

    @Test("tallies accumulate and clear on drain")
    func tally() {
        let name = "pacer.test.launch.\(UUID().uuidString)"
        let s = UserDefaults(suiteName: name)!
        s.removePersistentDomain(forName: name)
        LaunchOrigin.login.record(store: s)
        LaunchOrigin.manual.record(store: s)
        LaunchOrigin.manual.record(store: s)
        let first = LaunchOrigin.drain(store: s)
        #expect(first.login == 1 && first.manual == 2)
        let second = LaunchOrigin.drain(store: s)
        #expect(second.login == 0 && second.manual == 0)
    }

    @Test("resolve reads the login-item status only when the grace rule needs it")
    func resolveReadsStatusOnlyWhenNeeded() async {
        actor Reads { var count = 0; func add() { count += 1 } }
        let reads = Reads()
        let enabled: @Sendable () async -> Bool = { await reads.add(); return true }
        #expect(await LaunchOrigin.resolve(appleEventSaysLogin: true, secondsSinceBoot: 60,
                                           loginItemEnabled: enabled) == .login)
        #expect(await LaunchOrigin.resolve(appleEventSaysLogin: false, secondsSinceBoot: 4_000,
                                           loginItemEnabled: enabled) == .manual)
        #expect(await reads.count == 0)
        #expect(await LaunchOrigin.resolve(appleEventSaysLogin: false, secondsSinceBoot: 60,
                                           loginItemEnabled: enabled) == .login)
        #expect(await reads.count == 1)
    }

    /// Sentry PACER-N: the status read blocked the main thread for 2+ s.
    @Test("the login-item status is read off the main thread, even from the main actor")
    @MainActor
    func statusReadOffMain() async {
        #expect(pthread_main_np() != 0)
        let status = await LoginItemController.statusOffMain {
            #expect(pthread_main_np() == 0)
            return .enabled
        }
        #expect(status == .enabled)
    }
}
