import Foundation
import Testing
@testable import PacerCore

@Test func paceBandGreenWhenWellBehindPace() {
    // 60% pace elapsed but only 30% used → comfortably behind.
    #expect(PaceBand(usedPct: 30, paceEndPct: 60) == .green)
}

@Test func paceBandWhiteOnTrack() {
    // Within tolerance of pace.
    #expect(PaceBand(usedPct: 50, paceEndPct: 50) == .white)
    #expect(PaceBand(usedPct: 47, paceEndPct: 50) == .white)
    #expect(PaceBand(usedPct: 53, paceEndPct: 50) == .white)
}

@Test func paceBandYellowSlightlyAhead() {
    // 6pp ahead — out of tolerance, not yet red threshold.
    #expect(PaceBand(usedPct: 56, paceEndPct: 50) == .yellow)
}

@Test func paceBandRedAt90PercentRegardlessOfPace() {
    // 90%+ always reads red even if pace says you're "on track."
    #expect(PaceBand(usedPct: 90, paceEndPct: 95) == .red)
    #expect(PaceBand(usedPct: 100, paceEndPct: 100) == .red)
}

@Test func paceBandRedWhenMoreThan15ppAhead() {
    // 16pp ahead — red even at low absolute usage.
    #expect(PaceBand(usedPct: 50, paceEndPct: 33) == .red)
}

@Test func paceFractionAtWindowStart() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let resets = now.addingTimeInterval(5 * 3600)  // 5h ahead
    let frac = PaceMath.paceFraction(now: now, resetsAt: resets, windowDuration: 5 * 3600)
    #expect(frac == 0)
}

@Test func paceFractionAtMidWindow() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let resets = now.addingTimeInterval(2.5 * 3600)  // 2.5h ahead → halfway through 5h
    let frac = PaceMath.paceFraction(now: now, resetsAt: resets, windowDuration: 5 * 3600)
    #expect(abs(frac - 0.5) < 0.001)
}

@Test func paceFractionClampsToOne() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    // resetsAt was an hour ago — server clock skew. Should clamp to 1.
    let resets = now.addingTimeInterval(-3600)
    let frac = PaceMath.paceFraction(now: now, resetsAt: resets, windowDuration: 5 * 3600)
    #expect(frac == 1)
}

@Test func paceFractionClampsToZero() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    // resetsAt is way in the future — also clock skew. Should clamp to 0.
    let resets = now.addingTimeInterval(10 * 3600)
    let frac = PaceMath.paceFraction(now: now, resetsAt: resets, windowDuration: 5 * 3600)
    #expect(frac == 0)
}

@Test func windowDurationKnownKeys() {
    #expect(PaceMath.windowDuration(for: "five_hour") == TimeInterval(5 * 3600))
    #expect(PaceMath.windowDuration(for: "seven_day") == TimeInterval(7 * 86400))
    #expect(PaceMath.windowDuration(for: "unknown") == nil)
}
