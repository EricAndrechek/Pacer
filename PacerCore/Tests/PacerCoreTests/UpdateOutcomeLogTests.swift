import Foundation
import Testing
@testable import PacerCore

@Suite("Update outcome log")
struct UpdateOutcomeLogTests {

    private func suite() -> UserDefaults {
        let name = "pacer.test.update.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("error results carry a safe domain tail and the code")
    func errorResult() {
        #expect(UpdateOutcomeLog.result(forErrorDomain: "SUSparkleErrorDomain", code: 2001) == "error_sparkle_2001")
        #expect(UpdateOutcomeLog.result(forErrorDomain: "NSURLErrorDomain", code: -1009) == "error_nsurlerrordomain_-1009")
        #expect(UpdateOutcomeLog.result(forErrorDomain: "Foo.Bar Baz/x", code: 1) == "error_bar_baz_x_1")
    }

    @Test("a download failure keeps its error detail until a later result without one")
    func errorDetailKept() {
        let s = suite()
        let detail = UpdateOutcomeLog.errorDetail(domain: "NSURLErrorDomain", code: -1009,
                                                  underlyingDomain: "kCFErrorDomainCFNetwork", underlyingCode: -1)
        #expect(detail == "error_nsurlerrordomain_-1009/error_kcferrordomaincfnetwork_-1")
        #expect(UpdateOutcomeLog.errorDetail(domain: "SUSparkleErrorDomain", code: 2001) == "error_sparkle_2001")
        UpdateOutcomeLog.record(.downloadFailed, version: "1.2.3", error: detail, store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.error == detail)
        // The end-of-cycle repeat is ignored, so the reason survives it.
        UpdateOutcomeLog.record("error_sparkle_4005", endOfCycle: true, store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.error == detail)
        UpdateOutcomeLog.record(.found, version: "1.2.4", store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.error == nil)
    }

    @Test("the last result and version are kept together")
    func roundTrip() {
        let s = suite()
        #expect(UpdateOutcomeLog.last(store: s) == nil)
        UpdateOutcomeLog.record(.found, version: "0.7.8", store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.result == "found")
        #expect(UpdateOutcomeLog.last(store: s)?.version == "0.7.8")
        UpdateOutcomeLog.record(.noUpdate, store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.version == nil)
    }

    @Test("a version that is not identifier-like is dropped")
    func unsafeVersion() {
        let s = suite()
        UpdateOutcomeLog.record(.found, version: "Pacer for Eric's Mac", store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.version == nil)
    }

    @Test("an end-of-cycle error does not replace a fresh specific result")
    func endOfCycleKeepsSpecific() {
        let s = suite()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        UpdateOutcomeLog.record(.downloadFailed, version: "0.7.8", now: t, store: s)
        UpdateOutcomeLog.record("error_sparkle_2001", endOfCycle: true, now: t.addingTimeInterval(5), store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.result == "download_failed")
        UpdateOutcomeLog.record("error_sparkle_2001", endOfCycle: true, now: t.addingTimeInterval(600), store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.result == "error_sparkle_2001")
    }

    @Test("an end-of-cycle error does not replace a fresh idle install")
    func endOfCycleKeepsIdleInstall() {
        let s = suite()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        UpdateOutcomeLog.record(.idleInstall, version: "0.8.3", now: t, store: s)
        UpdateOutcomeLog.record("error_sparkle_4005", endOfCycle: true, now: t.addingTimeInterval(5), store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.result == "idle_install")
        #expect(UpdateOutcomeLog.last(store: s)?.version == "0.8.3")
    }

    @Test("a waiting update is not protected: the error that ends its cycle is the news")
    func endOfCycleReplacesReady() {
        let s = suite()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        UpdateOutcomeLog.record(.readyToInstall, version: "0.8.3", now: t, store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.result == "ready_to_install")
        UpdateOutcomeLog.record("error_sparkle_4005", endOfCycle: true, now: t.addingTimeInterval(5), store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.result == "error_sparkle_4005")
    }
}
