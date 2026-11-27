import Foundation
import Testing
@testable import PacerCore

@Suite("Update deferral (#470)")
struct UpdateDeferralTests {

    private typealias D = UpdateDeferral

    /// What every launch and scheduled check of a user's Pacer looks like.
    private let background = D.Found(background: true, automaticDownloads: true)

    @Test("a background check with automatic downloads on defers the download")
    func defersBackground() {
        #expect(D.decide(background, normalLaunch: true, arming: false, pendingFor: nil) == .defer)
        #expect(D.decide(background, normalLaunch: true, arming: false, pendingFor: 3600) == .defer)
    }

    @Test("the user's Check for Updates… is never vetoed, whatever else holds")
    func manualNeverVetoed() {
        for automatic in [true, false] {
            for critical in [true, false] {
                for normal in [true, false] {
                    for arming in [true, false] {
                        for pendingFor in [nil, 0, D.fallbackAfter - 1, D.fallbackAfter * 2] as [TimeInterval?] {
                            let manual = D.Found(background: false, automaticDownloads: automatic, critical: critical)
                            #expect(D.decide(manual, normalLaunch: normal, arming: arming, pendingFor: pendingFor)
                                    == .proceed(.userCheck))
                        }
                    }
                }
            }
        }
    }

    @Test("automatic downloads off: Sparkle asks first, as before; nothing to defer")
    func notAutomatic() {
        let found = D.Found(background: true, automaticDownloads: false)
        #expect(D.decide(found, normalLaunch: true, arming: false, pendingFor: nil) == .proceed(.notAutomatic))
    }

    @Test("critical, information-only and major upgrades are left to Sparkle")
    func needsAttention() {
        for found in [D.Found(background: true, automaticDownloads: true, critical: true),
                      D.Found(background: true, automaticDownloads: true, informationOnly: true),
                      D.Found(background: true, automaticDownloads: true, majorUpgrade: true)] {
            #expect(D.decide(found, normalLaunch: true, arming: false, pendingFor: nil) == .proceed(.needsAttention))
            #expect(D.decide(found, normalLaunch: true, arming: true, pendingFor: nil) == .proceed(.needsAttention))
        }
    }

    @Test("a diagnostic launch of the bundle defers nothing")
    func diagnosticLaunch() {
        #expect(D.decide(background, normalLaunch: false, arming: false, pendingFor: nil) == .proceed(.diagnosticLaunch))
    }

    @Test("the armed check downloads")
    func armingProceeds() {
        #expect(D.decide(background, normalLaunch: true, arming: true, pendingFor: 60) == .proceed(.arming))
        // Arming wins over the fallback: the hold it leads to fires at once.
        #expect(D.decide(background, normalLaunch: true, arming: true, pendingFor: D.fallbackAfter * 3)
                == .proceed(.arming))
    }

    @Test("pending for 72 h: the download goes ahead and today's hold takes over")
    func fallback() {
        #expect(D.fallbackAfter == 72 * 3600)
        #expect(D.decide(background, normalLaunch: true, arming: false, pendingFor: D.fallbackAfter - 1) == .defer)
        #expect(D.decide(background, normalLaunch: true, arming: false, pendingFor: D.fallbackAfter)
                == .proceed(.fallback))
        #expect(D.decide(background, normalLaunch: true, arming: false, pendingFor: 30 * 86400)
                == .proceed(.fallback))
    }

    @Test("the veto's error is Pacer's, and never a code Sparkle compares without its domain")
    func vetoError() {
        let error = D.error(version: "0.9.6")
        #expect(error.domain == "com.ericandrechek.pacer.update")
        // SUNoUpdateError, SUInstallationCanceledError, SUInstallationAuthorizeLaterError.
        #expect(![1001, 4007, 4008].contains(error.code))
        #expect(D.isDeferral(domain: error.domain, code: error.code))
        #expect(!D.isDeferral(domain: "SUSparkleErrorDomain", code: error.code))
        #expect(!D.isDeferral(domain: error.domain, code: 1001))
        // Sparkle's contract asks for a description.
        #expect(!(error.userInfo[NSLocalizedDescriptionKey] as? String ?? "").isEmpty)
        // Neither "up to date" nor a failure to the surfaces.
        #expect(UpdateState.isQuietEnd(domain: error.domain, code: error.code))
        #expect(!UpdateState.isNoUpdate(domain: error.domain, code: error.code))
        #expect(UpdateState.isQuietEnd(domain: "SUSparkleErrorDomain", code: 1001))
        #expect(!UpdateState.isQuietEnd(domain: "SUSparkleErrorDomain", code: 2001))
        // Not a feed failure either, even had the feed not been marked loaded.
        #expect(FeedFallback.appcastFailure(error, feedLoaded: false) == nil)
        #expect(FeedFallback.appcastFailure(error, feedLoaded: true) == nil)
    }

    @Test("a veto is never recorded as an error outcome")
    func vetoNotAnError() {
        let bag = TestDefaultsBag()
        let s = bag.make(prefix: "deferral")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        UpdateOutcomeLog.record(.available, version: "0.9.6", now: t, store: s)
        // The cycle the veto ended reports its error; it must not replace `available`.
        UpdateOutcomeLog.recordEndOfCycle(domain: D.errorDomain, code: D.errorCode,
                                          now: t.addingTimeInterval(1), store: s)
        let last = UpdateOutcomeLog.last(store: s)
        #expect(last?.result == "available")
        #expect(last?.version == "0.9.6")
        #expect(last?.error == nil)
        // A real failure after it is still recorded.
        UpdateOutcomeLog.recordEndOfCycle(domain: "SUSparkleErrorDomain", code: 2001,
                                          now: t.addingTimeInterval(600), store: s)
        #expect(UpdateOutcomeLog.last(store: s)?.result == "error_sparkle_2001")
    }

    @Test("how a cycle ended, from its error")
    func cycleEndClassification() {
        typealias E = UpdateSchedule.CycleEnd
        #expect(E.classify(errorDomain: nil, code: nil, feedLoaded: true) == .other)
        #expect(E.classify(errorDomain: D.errorDomain, code: D.errorCode, feedLoaded: true) == nil)
        #expect(E.classify(errorDomain: D.errorDomain, code: D.errorCode, feedLoaded: false) == nil)
        #expect(E.classify(errorDomain: "SUSparkleErrorDomain", code: 1001, feedLoaded: true) == .noUpdate)
        // Sparkle's 2001 is a failed appcast fetch or a failed download: the
        // appcast having loaded is what tells them apart.
        #expect(E.classify(errorDomain: "SUSparkleErrorDomain", code: 2001, feedLoaded: false) == .feedFailed)
        #expect(E.classify(errorDomain: "SUSparkleErrorDomain", code: 2001, feedLoaded: true) == .downloadFailed)
        #expect(E.classify(errorDomain: "SUSparkleErrorDomain", code: 3002, feedLoaded: true) == .downloadFailed)
        #expect(E.classify(errorDomain: NSURLErrorDomain, code: -1009, feedLoaded: false) == .feedFailed)
    }
}

@Suite("Update schedule (#470)")
struct UpdateScheduleTests {

    private typealias S = UpdateSchedule
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let install = UpdateInstallPolicy.Decision.install(.noWindow)

    private func available(_ version: String = "0.9.6", build: String = "1806", at: Date? = nil) -> S {
        var s = S()
        s.deferred(version: version, build: build, now: at ?? t0, currentBuild: "1800")
        return s
    }

    private func verdict(_ s: S, at: Date, policy: UpdateInstallPolicy.Decision? = nil, busy: Bool = false,
                         checks: Bool = true, downloads: Bool = true) -> S.ArmVerdict {
        s.armVerdict(now: at, policy: policy ?? install, sessionInProgress: busy,
                     automaticChecks: checks, automaticDownloads: downloads)
    }

    @Test("idle: a deferral makes the update available from that moment, on this build")
    func firstSighting() {
        var s = S()
        #expect(s.offeredVersion == nil && !s.needsTimer)
        let r1 = s.deferred(version: "0.9.6", build: "1806", now: t0, currentBuild: "1800")
        #expect(r1)
        #expect(s.phase == .available(.init(version: "0.9.6", build: "1806", since: t0, fromBuild: "1800")))
        #expect(s.offeredVersion == "0.9.6")
        #expect(s.heldVersion == nil)
        #expect(!s.isInstalling)
        #expect(s.needsTimer)
    }

    @Test("a newer release replaces the pending one and keeps the first sighting")
    func newerKeepsSince() {
        var s = available()
        let r2 = s.deferred(version: "0.9.6", build: "1806", now: t0.addingTimeInterval(6 * 3600), currentBuild: "1800")
        #expect(!r2)
        let r3 = s.deferred(version: "0.9.7", build: "1807", now: t0.addingTimeInterval(12 * 3600), currentBuild: "1800")
        #expect(r3)
        #expect(s.pending == .init(version: "0.9.7", build: "1807", since: t0, fromBuild: "1800"))
    }

    @Test("available arms when the policy says install and Sparkle is idle")
    func armsOnPolicy() {
        let s = available()
        #expect(verdict(s, at: t0.addingTimeInterval(60)) == .arm(.policy))
        #expect(verdict(s, at: t0, policy: .wait(.dashboardOpen)) == .wait(.dashboardOpen))
        #expect(verdict(S(), at: t0) == .none)
    }

    @Test("arming waits while Sparkle's session is in progress, then arms")
    func armingWhileSessionInProgress() {
        var s = available()
        #expect(verdict(s, at: t0, busy: true) == .busy)
        // Counted once per wish to arm, not once a minute.
        let r4 = s.noteBusy()
        #expect(r4)
        let r5 = s.noteBusy()
        #expect(!r5)
        #expect(verdict(s, at: t0.addingTimeInterval(60), busy: true) == .busy)
        #expect(verdict(s, at: t0.addingTimeInterval(120), busy: false) == .arm(.policy))
        s.armed(.policy, now: t0.addingTimeInterval(120))
        #expect(s.isArming)
        // A new wish after this arm counts again.
        _ = s.cycleEnded(.feedFailed)
        let r6 = s.noteBusy()
        #expect(r6)
    }

    @Test("automatic checks or downloads off: nothing is armed")
    func optedOut() {
        var s = available()
        #expect(verdict(s, at: t0, checks: false) == .optedOut)
        #expect(verdict(s, at: t0, downloads: false) == .optedOut)
        #expect(verdict(s, at: t0, checks: false, downloads: false) == .optedOut)
        // Not even a waiting click.
        let r7 = s.clicked(sessionInProgress: true)
        #expect(r7 == .waiting)
        #expect(verdict(s, at: t0, busy: false, checks: false) == .optedOut)
        s.clear()
        #expect(s.phase == .idle)
        #expect(verdict(s, at: t0) == .none)
    }

    @Test("attempts are spaced half an hour apart, and a clock set back does not stall them")
    func spacing() {
        var s = available()
        s.armed(.policy, now: t0)
        let r8 = s.cycleEnded(.downloadFailed)
        #expect(r8 == .downloadFailed)
        #expect(s.phase == .available(s.pending!))
        #expect(verdict(s, at: t0.addingTimeInterval(S.armSpacing - 1)) == .spacing)
        #expect(verdict(s, at: t0.addingTimeInterval(S.armSpacing)) == .arm(.policy))
        #expect(verdict(s, at: t0.addingTimeInterval(-3600)) == .arm(.policy))
        #expect(S.armSpacing == 30 * 60)
    }

    @Test("an armed hold asks the policy from the first sighting; a requested one installs at once")
    func armedHolds() {
        var policy = available(at: t0)
        policy.armed(.policy, now: t0.addingTimeInterval(3600))
        let r9 = policy.held(version: "0.9.7")
        #expect(r9 == .policy(since: t0))
        #expect(policy.heldVersion == "0.9.7")
        #expect(policy.offeredVersion == "0.9.7")
        #expect(!policy.isInstalling)

        var requested = available(at: t0)
        let r10 = requested.clicked(sessionInProgress: false)
        #expect(r10 == .arm)
        requested.armed(.requested, now: t0.addingTimeInterval(60))
        // The click greys the action from the moment it arms.
        #expect(requested.isInstalling)
        let r11 = requested.held(version: "0.9.7")
        #expect(r11 == .installNow)
    }

    @Test("a hold no arm led to waits for the policy: the fallback from the first sighting, a critical one from now")
    func unarmedHolds() {
        // The 72 h fallback: downloaded while merely available. Its clock is
        // the first sighting's, so the policy's ceiling is already behind it.
        var fallback = available()
        let r12 = fallback.held(version: "0.9.6")
        #expect(r12 == .policy(since: t0))
        fallback.released()
        #expect(fallback.phase == .available(.init(version: "0.9.6", build: "1806", since: t0, fromBuild: "1800")))
        // A critical update, nothing pending.
        var critical = S()
        let r13 = critical.held(version: "0.9.6")
        #expect(r13 == .policy(since: nil))
        critical.released()
        #expect(critical.phase == .idle)
    }

    @Test("held → installing → back to held if Pacer is still here; released → pending again")
    func installing() {
        var s = available()
        s.armed(.policy, now: t0)
        _ = s.held(version: "0.9.6")
        s.fired()
        #expect(s.isInstalling)
        #expect(s.heldVersion == "0.9.6")
        s.installDidNotHappen()
        #expect(!s.isInstalling)
        if case .held = s.phase {} else { Issue.record("expected held, got \(s.phase)") }
        s.released()
        #expect(s.phase == .available(.init(version: "0.9.6", build: "1806", since: t0, fromBuild: "1800")))
        // Its next arm reads the feed afresh, after the spacing.
        #expect(verdict(s, at: t0.addingTimeInterval(60)) == .spacing)
    }

    @Test("how an arm ends: nothing newer clears it, failures leave it pending")
    func armOutcomes() {
        var none = available()
        none.armed(.policy, now: t0)
        let r14 = none.cycleEnded(.noUpdate)
        #expect(r14 == .nothingNewer)
        #expect(none.phase == .idle)

        for (end, outcome) in [(S.CycleEnd.feedFailed, S.ArmOutcome.feedFailed), (.downloadFailed, .downloadFailed)] {
            var s = available()
            s.armed(.requested, now: t0)
            let r15 = s.cycleEnded(end)
            #expect(r15 == outcome)
            #expect(s.phase == .available(s.pending!))
            #expect(!s.isInstalling)
        }

        var other = available()
        other.armed(.policy, now: t0)
        let r16 = other.cycleEnded(.other)
        #expect(r16 == nil)
        #expect(other.pending != nil && !other.isArming)

        // A check while merely available that finds nothing: the release was pulled.
        var pulled = available()
        let r17 = pulled.cycleEnded(.noUpdate)
        #expect(r17 == nil)
        #expect(pulled.phase == .idle)
        var stillThere = available()
        let r18 = stillThere.cycleEnded(.feedFailed)
        #expect(r18 == nil)
        #expect(stillThere.pending != nil)
    }

    @Test("the counters' names")
    func counterKeys() {
        #expect(S.ArmOutcome.allCases.map(\.counterKey) == [
            "update.arm.held", "update.arm.installed", "update.arm.nothing_newer",
            "update.arm.feed_failed", "update.arm.download_failed", "update.arm.needs_authorization",
            "update.arm.busy",
        ])
    }

    @Test("a click arms at once, waits out a busy Sparkle, and needs neither the policy nor the spacing")
    func clicks() {
        var s = available()
        s.armed(.policy, now: t0)
        _ = s.cycleEnded(.feedFailed)
        let r19 = s.clicked(sessionInProgress: true)
        #expect(r19 == .waiting)
        #expect(s.clicked)
        #expect(s.isRequested)
        #expect(verdict(s, at: t0.addingTimeInterval(1), policy: .wait(.inUse), busy: true) == .busy)
        #expect(verdict(s, at: t0.addingTimeInterval(2), policy: .wait(.inUse), busy: false) == .arm(.requested))
        s.armed(.requested, now: t0.addingTimeInterval(2))
        #expect(s.isArming && s.isRequested)

        // A click during the policy's arm makes it install as soon as it is handed over.
        var policyArm = available()
        policyArm.armed(.policy, now: t0)
        #expect(!policyArm.isInstalling)
        let r20 = policyArm.clicked(sessionInProgress: true)
        #expect(r20 == .nothing)
        #expect(policyArm.isInstalling)
        let r21 = policyArm.held(version: "0.9.6")
        #expect(r21 == .installNow)

        let r22 = policyArm.clicked(sessionInProgress: true)
        #expect(r22 == .installHeld)
        policyArm.fired()
        let r23 = policyArm.clicked(sessionInProgress: true)
        #expect(r23 == .nothing)
        var idle = S()
        let r24 = idle.clicked(sessionInProgress: false)
        #expect(r24 == .nothing)
    }

    @Test("a deferral during an arm or a hold changes nothing")
    func deferralOutOfPlace() {
        var arming = available()
        arming.armed(.policy, now: t0)
        let before = arming
        let r25 = arming.deferred(version: "0.9.9", build: "1809", now: t0, currentBuild: "1800")
        #expect(!r25)
        #expect(arming == before)
        var held = before
        _ = held.held(version: "0.9.6")
        let heldBefore = held
        let r26 = held.deferred(version: "0.9.9", build: "1809", now: t0, currentBuild: "1800")
        #expect(!r26)
        #expect(held == heldBefore)
    }

    @Test("clear drops what is pending, never a hold")
    func clearing() {
        var arming = available()
        arming.armed(.policy, now: t0)
        arming.clear()
        #expect(arming.phase == .idle)
        var held = available()
        _ = held.held(version: "0.9.6")
        held.clear()
        #expect(held.heldVersion == "0.9.6")
    }

    @Test("an arm Sparkle refused to start is pending again")
    func armDidNotStart() {
        var s = available()
        s.armed(.policy, now: t0)
        s.armDidNotStart()
        #expect(s.phase == .available(s.pending!))
        #expect(s.lastAttempt == t0)
    }

    @Test("at launch: pending on this build is restored; deferred on another build, it is gone")
    func restore() {
        let pending = S.Pending(version: "0.9.6", build: "1806", since: t0, fromBuild: "1800")
        #expect(S(restoring: pending, lastAttempt: t0, currentBuild: "1800", now: t0).phase == .available(pending))
        #expect(S(restoring: pending, lastAttempt: t0, currentBuild: "1800", now: t0).lastAttempt == t0)
        let updated = S(restoring: pending, lastAttempt: t0, currentBuild: "1806", now: t0)
        #expect(updated.phase == .idle)
        #expect(updated.lastAttempt == nil)
        #expect(S(restoring: nil, lastAttempt: nil, currentBuild: "1800", now: t0).phase == .idle)
    }

    @Test("what outlives a launch round-trips, and an armed install is counted once on the new build")
    func store() {
        let bag = TestDefaultsBag()
        let d = bag.make(prefix: "schedule")
        var s = available()
        s.armed(.policy, now: t0.addingTimeInterval(30))
        UpdateScheduleStore.save(s, d)
        let loaded = UpdateScheduleStore.load(d)
        #expect(loaded.pending == s.pending)
        #expect(loaded.lastAttempt == t0.addingTimeInterval(30))
        UpdateScheduleStore.save(S(), d)
        #expect(UpdateScheduleStore.load(d).pending == nil)
        #expect(UpdateScheduleStore.load(d).lastAttempt == nil)
        // Garbage in the defaults is no pending update.
        d.set(Data("nope".utf8), forKey: UpdateScheduleStore.pendingKey)
        #expect(UpdateScheduleStore.load(d).pending == nil)

        #expect(!UpdateScheduleStore.takeArmedInstall(currentBuild: "1806", d))
        UpdateScheduleStore.noteArmedInstall(fromBuild: "1800", d)
        // Relaunched on the same build: the install did not happen.
        #expect(!UpdateScheduleStore.takeArmedInstall(currentBuild: "1800", d))
        #expect(!UpdateScheduleStore.takeArmedInstall(currentBuild: "1806", d))
        UpdateScheduleStore.noteArmedInstall(fromBuild: "1800", d)
        #expect(UpdateScheduleStore.takeArmedInstall(currentBuild: "1806", d))
        #expect(!UpdateScheduleStore.takeArmedInstall(currentBuild: "1806", d))
    }

    @Test("the whole path: B deferred, C deferred, the install moment installs C once")
    func installsNewestOnce() {
        var s = S()
        s.deferred(version: "B", build: "2", now: t0, currentBuild: "1")
        s.deferred(version: "C", build: "3", now: t0.addingTimeInterval(6 * 3600), currentBuild: "1")
        let at = t0.addingTimeInterval(7 * 3600)
        #expect(verdict(s, at: at) == .arm(.policy))
        s.armed(.policy, now: at)
        // Sparkle reads the feed at the arm and hands over C.
        let r27 = s.held(version: "C")
        #expect(r27 == .policy(since: t0))
        s.fired()
        #expect(s.phase == .installing(version: "C",
                                       pending: .init(version: "C", build: "3", since: t0, fromBuild: "1"),
                                       armed: .policy))
        // Relaunched on C: nothing pending.
        #expect(S(restoring: s.pending, lastAttempt: s.lastAttempt, currentBuild: "3", now: t0).phase == .idle)
    }
    // MARK: - Review fixes

    @Test("an arm that could not reach the site is retried by the fallback's re-check, past the policy and the spacing")
    func failoverArms() {
        var s = available()
        let notAnArm = s.failoverVerdict(sessionInProgress: false, automaticChecks: true, automaticDownloads: true)
        // A plain check that failed: the re-check is a plain check too.
        #expect(notAnArm == .none)
        s.armed(.policy, now: t0)
        let r1 = s.cycleEnded(.feedFailed)
        #expect(r1 == .feedFailed)
        #expect(s.feedFailedArm == .policy)
        #expect(s.failures == 0)
        let at = t0.addingTimeInterval(15 * 60)
        // The policy's own clock still says wait, and the spacing too…
        #expect(verdict(s, at: at, policy: .wait(.inUse)) == .wait(.inUse))
        #expect(verdict(s, at: at) == .spacing)
        // …but the failover re-check is the arm.
        #expect(s.failoverVerdict(sessionInProgress: false, automaticChecks: true, automaticDownloads: true)
                == .arm(.policy))
        #expect(s.failoverVerdict(sessionInProgress: true, automaticChecks: true, automaticDownloads: true) == .busy)
        #expect(s.failoverVerdict(sessionInProgress: false, automaticChecks: false, automaticDownloads: true)
                == .optedOut)
        s.armed(.policy, now: at)
        #expect(s.feedFailedArm == nil)
        // Its hold still waits on the policy, from the first sighting.
        let r2 = s.held(version: "0.9.6")
        #expect(r2 == .policy(since: t0))

        // A clicked arm that could not reach the site retries as clicked.
        var clicked = available()
        clicked.armed(.requested, now: t0)
        _ = clicked.cycleEnded(.feedFailed)
        #expect(clicked.failoverVerdict(sessionInProgress: false, automaticChecks: true, automaticDownloads: true)
                == .arm(.requested))

        // Not after an arm that got past the feed.
        var downloaded = available()
        downloaded.armed(.policy, now: t0)
        _ = downloaded.cycleEnded(.downloadFailed)
        #expect(downloaded.failoverVerdict(sessionInProgress: false, automaticChecks: true, automaticDownloads: true)
                == .none)
    }

    @Test("failed arms back off like failed downloads: 30 min, 2 h, then 6 h")
    func backoff() {
        #expect(S.retrySpacing(afterFailures: 0) == 30 * 60)
        #expect(S.retrySpacing(afterFailures: 1) == 30 * 60)
        #expect(S.retrySpacing(afterFailures: 2) == 2 * 3600)
        #expect(S.retrySpacing(afterFailures: 3) == 6 * 3600)
        #expect(S.retrySpacing(afterFailures: 9) == 6 * 3600)

        var s = available()
        var at = t0
        for (n, wait) in [(1, 30 * 60.0), (2, 2 * 3600.0), (3, 6 * 3600.0), (4, 6 * 3600.0)] {
            s.armed(.policy, now: at)
            s.noteDownloadStarted()
            let r = s.cycleEnded(.other)
            // A download that started and got no hold failed, whatever the error said.
            #expect(r == .downloadFailed)
            #expect(s.failures == n)
            #expect(verdict(s, at: at.addingTimeInterval(wait - 1)) == .spacing)
            #expect(verdict(s, at: at.addingTimeInterval(wait)) == .arm(.policy))
            at = at.addingTimeInterval(wait)
        }
        // An unreachable feed costs no download: it neither adds nor resets.
        s.armed(.policy, now: at)
        _ = s.cycleEnded(.feedFailed)
        #expect(s.failures == 4)

        // A newer release starts again.
        var newer = s
        newer.deferred(version: "0.9.7", build: "1807", now: at, currentBuild: "1800")
        #expect(newer.failures == 0)
        // So does a hold.
        var held = s
        held.armed(.policy, now: at.addingTimeInterval(7 * 3600))
        _ = held.held(version: "0.9.6")
        #expect(held.failures == 0)
        // And the update going away.
        var gone = s
        gone.armed(.policy, now: at.addingTimeInterval(7 * 3600))
        _ = gone.cycleEnded(.noUpdate)
        #expect(gone.failures == 0)

        // The count outlives a launch on the same build, not on another.
        let bag = TestDefaultsBag()
        let d = bag.make(prefix: "backoff")
        UpdateScheduleStore.save(s, d)
        let loaded = UpdateScheduleStore.load(d)
        #expect(loaded.failures == 4)
        #expect(S(restoring: loaded.pending, lastAttempt: loaded.lastAttempt, failures: loaded.failures,
                  currentBuild: "1800", now: at).failures == 4)
        #expect(S(restoring: loaded.pending, lastAttempt: loaded.lastAttempt, failures: loaded.failures,
                  currentBuild: "1806", now: at).failures == 0)
        UpdateScheduleStore.save(S(), d)
        #expect(UpdateScheduleStore.load(d).failures == 0)
    }

    @Test("Sparkle asking for authorization backs off too, so its dialog does not come back every half hour")
    func authorization() {
        typealias E = S.CycleEnd
        #expect(E.classify(errorDomain: "SUSparkleErrorDomain", code: 4008, feedLoaded: true) == .needsAuthorization)
        #expect(E.classify(errorDomain: "SUSparkleErrorDomain", code: 4007, feedLoaded: false) == .needsAuthorization)
        #expect(E.classify(errorDomain: "elsewhere", code: 4008, feedLoaded: true) == .downloadFailed)

        var s = available()
        s.armed(.policy, now: t0)
        s.noteDownloadStarted()
        // 4008 keeps the download and Sparkle shows its dialog at once; the
        // cycle that ends is the dialog's, often with no error at all.
        s.noteShownToUser()
        let r1 = s.cycleEnded(.other)
        #expect(r1 == .needsAuthorization)
        #expect(s.failures == 1)
        #expect(verdict(s, at: t0.addingTimeInterval(30 * 60 - 1)) == .spacing)
        s.armed(.policy, now: t0.addingTimeInterval(30 * 60))
        let r2 = s.cycleEnded(.needsAuthorization)
        #expect(r2 == .needsAuthorization)
        #expect(verdict(s, at: t0.addingTimeInterval(30 * 60 + 2 * 3600 - 1)) == .spacing)
        // Outside an arm, a dialog is not ours to count.
        var idle = available()
        idle.noteShownToUser()
        #expect(idle.cycleEnded(.other) == nil)
    }

    @Test("a first sighting in the future (the clock was set back) is now")
    func clockSetBack() {
        var s = available(at: t0)
        let earlier = t0.addingTimeInterval(-5 * 86400)
        s.clamp(now: earlier)
        #expect(s.pending?.since == earlier)
        // So the 72 h fallback and the policy count from a real moment again.
        let later = earlier.addingTimeInterval(UpdateDeferral.fallbackAfter)
        let pendingFor = later.timeIntervalSince(s.pending!.since)
        #expect(UpdateDeferral.decide(.init(background: true, automaticDownloads: true), normalLaunch: true,
                                      arming: false, pendingFor: pendingFor) == .proceed(.fallback))
        // The next deferral clamps as well, and a past since is left alone.
        var again = available(at: t0)
        again.deferred(version: "0.9.6", build: "1806", now: earlier, currentBuild: "1800")
        #expect(again.pending?.since == earlier)
        again.clamp(now: t0)
        #expect(again.pending?.since == earlier)
        // A restore too.
        let future = S.Pending(version: "0.9.6", build: "1806", since: t0, fromBuild: "1800")
        #expect(S(restoring: future, lastAttempt: nil, currentBuild: "1800", now: earlier).pending?.since == earlier)
        // And a hold's.
        var held = available(at: t0)
        _ = held.held(version: "0.9.6")
        held.clamp(now: earlier)
        #expect(held.pending?.since == earlier)
    }

    @Test("a click is never lost: a critical update the arm found instead, or a fallback already downloading")
    func clicksKept() {
        // The clicked arm finds a critical update: Sparkle downloads it, and it installs as clicked.
        var critical = available()
        critical.armed(.requested, now: t0)
        critical.handOver()
        #expect(critical.phase == .idle)
        #expect(critical.clicked)
        let r1 = critical.held(version: "0.9.9")
        #expect(r1 == .installNow)
        #expect(!critical.clicked)

        // A click during the policy's arm, handed over, the same.
        var policy = available()
        policy.armed(.policy, now: t0)
        _ = policy.clicked(sessionInProgress: true)
        policy.handOver()
        let r2 = policy.held(version: "0.9.9")
        #expect(r2 == .installNow)

        // Handed over without a click: as before.
        var unasked = available()
        unasked.armed(.policy, now: t0)
        unasked.handOver()
        #expect(!unasked.clicked)
        let r3 = unasked.held(version: "0.9.9")
        #expect(r3 == .policy(since: nil))

        // An information-only update Sparkle shows instead: the click ends with its cycle.
        var info = available()
        info.armed(.requested, now: t0)
        info.handOver()
        _ = info.cycleEnded(.other)
        #expect(!info.clicked)
        let r4 = info.held(version: "1.0.0")
        #expect(r4 == .policy(since: nil))

        // Clicked while Sparkle was busy with a check that turned out to be
        // the 72 h fallback's download: its hold installs as clicked.
        var fallback = available()
        let r5 = fallback.clicked(sessionInProgress: true)
        #expect(r5 == .waiting)
        let r6 = fallback.held(version: "0.9.6")
        #expect(r6 == .installNow)
        #expect(fallback.phase == .held(version: "0.9.6", pending: fallback.pending, armed: .requested))

        // A clicked arm that fails is clickable again.
        var failed = available()
        failed.armed(.requested, now: t0)
        #expect(failed.isRequested)
        _ = failed.cycleEnded(.downloadFailed)
        #expect(!failed.isRequested && !failed.clicked)
    }
}

