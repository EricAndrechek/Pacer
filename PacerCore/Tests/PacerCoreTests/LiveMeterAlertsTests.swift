import Foundation
import Testing
@testable import PacerCore

/// Threshold alerts from the live meter's estimates (#318), when Settings →
/// Notifications → "Alert from" includes them: the same per-cycle,
/// per-threshold dedup as readings, so nothing alerts twice, and resets judged
/// on readings only, so an estimate corrected down never posts anything.
@Suite("Live meter: alerts from estimates")
struct LiveMeterAlertsTests {

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let reset = t0.addingTimeInterval(3 * 3600)
    static let key = "acct|five_hour"
    static let thresholds = [50, 75, 90]

    /// What `NotificationCoordinator` does with a step: post what crossed and
    /// was not yet notified under any of its cycle's keys.
    struct Banners {
        var notified = Set<String>()
        var posted: [(threshold: Int, estimated: Bool)] = []

        mutating func judge(previous: Double?, current: Double, resetsAt: Date?, estimated: Bool) {
            let marked = notified
            for (t, key) in RateLimitAlertRules.toPost(
                windowKey: "five_hour#acct", previous: previous, current: current,
                thresholds: LiveMeterAlertsTests.thresholds, resetsAt: resetsAt,
                notified: { marked.contains($0) }) {
                notified.insert(key)
                posted.append((t, estimated))
            }
        }
    }

    static func reading(_ state: inout AlertCrossingState, _ banners: inout Banners, _ pct: Double,
                        at seconds: TimeInterval, resetsAt: Date = reset) -> AlertCrossingState.Step? {
        let step = state.advance(key, percent: pct, resetsAt: resetsAt, sampledAt: t0.addingTimeInterval(seconds))
        if let step { banners.judge(previous: step.previousPercent, current: pct, resetsAt: resetsAt, estimated: false) }
        return step
    }

    static func estimate(_ state: inout AlertCrossingState, _ banners: inout Banners, whole: Double,
                         on reading: Double, readAt: TimeInterval, at seconds: TimeInterval,
                         resetsAt: Date = reset, restarted: Bool = false) {
        let live = LiveMeterValue(
            percent: whole, reading: MeterReading(at: t0.addingTimeInterval(readAt), percent: reading,
                                                  resetsAt: resetsAt),
            addedPoints: whole - reading, exactAdded: whole - reading + 0.3, spendUSD: 5,
            rateSource: .perModel, restarted: restarted, asOf: t0.addingTimeInterval(seconds),
            exactPercent: whole + 0.3)
        if let step = state.advanceEstimate(key, live: live) {
            banners.judge(previous: step.previousPercent, current: whole, resetsAt: resetsAt, estimated: true)
        }
    }

    /// An estimate crosses 75 first and is announced as one; the reading that
    /// follows (here corrected down, then up across it, its `resets_at`
    /// jittered across a second) finds the same cycle's key and says
    /// nothing. One banner, said to be an estimate.
    @Test func aLineCrossedByAnEstimateThenTheReadingIsAnnouncedOnce() {
        var state = AlertCrossingState()
        var banners = Banners()
        _ = Self.reading(&state, &banners, 70, at: 0)                 // first: recorded silently
        _ = Self.reading(&state, &banners, 72, at: 30)
        Self.estimate(&state, &banners, whole: 73, on: 72, readAt: 30, at: 40)
        Self.estimate(&state, &banners, whole: 75, on: 72, readAt: 30, at: 50)
        #expect(banners.posted.count == 1)
        #expect(banners.posted.first?.threshold == 75)
        #expect(banners.posted.first?.estimated == true)
        // The next reading corrects it down: nothing, and no reset.
        let jitter = Self.reset.addingTimeInterval(0.6)
        let down = Self.reading(&state, &banners, 74, at: 60, resetsAt: jitter)
        #expect(down.map { RateLimitAlertRules.isReset(previousPct: $0.previousPercent, currentPct: 74,
                                                       previousResetsAt: $0.previousResetsAt,
                                                       resetsAt: jitter) } == false)
        // The estimate climbs over it again, then the reading does: still one.
        Self.estimate(&state, &banners, whole: 76, on: 74, readAt: 60, at: 70, resetsAt: jitter)
        _ = Self.reading(&state, &banners, 77, at: 90, resetsAt: Self.reset.addingTimeInterval(-0.4))
        #expect(banners.posted.count == 1)
        // 90 is still to come, once.
        _ = Self.reading(&state, &banners, 91, at: 120)
        Self.estimate(&state, &banners, whole: 92, on: 91, readAt: 120, at: 130)
        #expect(banners.posted.map(\.threshold) == [75, 90])
    }

    /// A line a reading crossed is announced as a reading: an estimate is not
    /// judged until the reading it is built on has been.
    @Test func theReadingGoesFirst() {
        var state = AlertCrossingState()
        var banners = Banners()
        _ = Self.reading(&state, &banners, 70, at: 0)
        // An estimate on a reading the readings path has not seen yet.
        Self.estimate(&state, &banners, whole: 77, on: 76, readAt: 30, at: 35)
        #expect(banners.posted.isEmpty)
        _ = Self.reading(&state, &banners, 76, at: 30)
        Self.estimate(&state, &banners, whole: 77, on: 76, readAt: 30, at: 40)
        #expect(banners.posted.map(\.threshold) == [75])
        #expect(banners.posted.first?.estimated == false)
    }

    /// Resets come from readings only. An estimate that climbed to 97 and
    /// was corrected down never enters the readings' state, so the reset
    /// rule still compares two readings, and with `resets_at` unmoved, a
    /// lower reading is no reset.
    @Test func onlyReadingsAnnounceAReset() {
        var state = AlertCrossingState()
        var banners = Banners()
        _ = Self.reading(&state, &banners, 60, at: 0)
        _ = Self.reading(&state, &banners, 88, at: 30)
        Self.estimate(&state, &banners, whole: 97, on: 88, readAt: 30, at: 40)
        let corrected = Self.reading(&state, &banners, 5, at: 60)
        #expect(corrected?.previousPercent == 88)             // the reading before, never the estimate
        #expect(corrected.map { RateLimitAlertRules.isReset(previousPct: $0.previousPercent, currentPct: 5,
                                                            previousResetsAt: $0.previousResetsAt,
                                                            resetsAt: Self.reset) } == false)
        // A real rollover, from readings: the reset instant moved on.
        let next = Self.reset.addingTimeInterval(5 * 3600)
        let rolled = Self.reading(&state, &banners, 3, at: 90, resetsAt: next)
        #expect(rolled.map { RateLimitAlertRules.isReset(previousPct: 88, currentPct: 3,
                                                         previousResetsAt: $0.previousResetsAt,
                                                         resetsAt: next) } == true)
        // An estimate restarted past its reset is not judged at all: the new
        // window's reset (and with it the dedup key) is not known yet.
        var fresh = AlertCrossingState()
        var none = Banners()
        _ = Self.reading(&fresh, &none, 40, at: 0)
        Self.estimate(&fresh, &none, whole: 55, on: 40, readAt: 0, at: 10, restarted: true)
        #expect(none.posted.isEmpty)
    }

    /// The estimate's text says it is one; a reading's is unchanged.
    @Test func theBannerSaysItIsAnEstimate() {
        #expect(RateLimitAlertRules.thresholdBody(label: "5-hour", percent: 75, threshold: 75, estimated: false)
                == "5-hour usage hit 75% (threshold 75%).")
        #expect(RateLimitAlertRules.thresholdBody(label: "5-hour", percent: 75, threshold: 75, estimated: true)
                == "5-hour usage is estimated at 75% (threshold 75%).")
    }

    /// One cycle, one key, whatever the server's millisecond jitter; the key
    /// written before this still counts, so nothing notified re-fires.
    @Test func aCycleHasOneKeyAcrossJitter() {
        let a = RateLimitAlertRules.thresholdKeys(windowKey: "w", threshold: 75, resetsAt: Self.reset.addingTimeInterval(-0.4))
        let b = RateLimitAlertRules.thresholdKeys(windowKey: "w", threshold: 75, resetsAt: Self.reset.addingTimeInterval(0.6))
        #expect(a[0] == b[0])
        let legacy = "notif.w.75.\(ISO8601DateFormatter().string(from: Self.reset.addingTimeInterval(0.6)))"
        #expect(b.contains(legacy))
        #expect(RateLimitAlertRules.toPost(windowKey: "w", previous: 70, current: 80, thresholds: [75],
                                           resetsAt: Self.reset.addingTimeInterval(0.6),
                                           notified: { $0 == legacy }).isEmpty)
        #expect(RateLimitAlertSource.current(from: UserDefaults(suiteName: "pacer.test.alertsource.\(UUID())")!)
                == .readings)
    }
}
