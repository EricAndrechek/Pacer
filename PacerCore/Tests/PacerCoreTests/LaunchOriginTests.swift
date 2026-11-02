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
}
