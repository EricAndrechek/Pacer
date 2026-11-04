import Foundation
import Testing
@testable import PacerCore

@Suite("Telemetry toggles: two-toggle migration")
struct TelemetryConsentTests {

    private func store() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "consent-\(UUID().uuidString)"))
    }

    /// nil = key absent (never touched), else the stored old value.
    private func seeded(crash: Bool?, usage: Bool?) throws -> UserDefaults {
        let s = try store()
        if let crash { s.set(crash, forKey: PacerPreferenceKeys.telemetryCrashReports) }
        if let usage { s.set(usage, forKey: PacerPreferenceKeys.telemetryUsageData) }
        return s
    }

    struct Row: Sendable, CustomStringConvertible {
        let crash: Bool?, usage: Bool?
        let expected: TelemetryConsent.State
        var description: String { "crash=\(String(describing: crash)) usage=\(String(describing: usage))" }
    }

    static let matrix: [Row] = [
        // Fresh install / never touched: everything on.
        Row(crash: nil, usage: nil, expected: .init(crashes: true, performance: true, usage: true)),
        Row(crash: true, usage: true, expected: .init(crashes: true, performance: true, usage: true)),
        Row(crash: nil, usage: true, expected: .init(crashes: true, performance: true, usage: true)),
        // Old usage off: PostHog off AND Sentry performance held off; crashes still go.
        Row(crash: true, usage: false, expected: .init(crashes: true, performance: false, usage: false)),
        Row(crash: nil, usage: false, expected: .init(crashes: true, performance: false, usage: false)),
        // Old crash off: nothing to Sentry, performance included.
        Row(crash: false, usage: true, expected: .init(crashes: false, performance: false, usage: true)),
        Row(crash: false, usage: nil, expected: .init(crashes: false, performance: false, usage: true)),
        Row(crash: false, usage: false, expected: .init(crashes: false, performance: false, usage: false)),
    ]

    @Test("upgrade never turns on something the user refused", arguments: matrix)
    func migrationMatrix(_ row: Row) throws {
        let s = try seeded(crash: row.crash, usage: row.usage)
        TelemetryConsent.migrate(store: s)
        #expect(TelemetryConsent.state(store: s) == row.expected)
        #expect(s.bool(forKey: PacerPreferenceKeys.telemetryMigrated))
    }

    @Test("runs once: a usage-off chosen after the migration does not hold performance")
    func onlyOnce() throws {
        let s = try seeded(crash: true, usage: true)
        TelemetryConsent.migrate(store: s)
        s.set(false, forKey: PacerPreferenceKeys.telemetryUsageData)
        TelemetryConsent.migrate(store: s)
        #expect(TelemetryConsent.state(store: s) == .init(crashes: true, performance: true, usage: false))
    }

    @Test("the hold lifts when the user changes either toggle")
    func holdLifts() throws {
        let s = try seeded(crash: true, usage: false)
        TelemetryConsent.migrate(store: s)
        #expect(!TelemetryConsent.state(store: s).performance)
        // They turn usage data back on: both follow their own toggles now.
        s.set(true, forKey: PacerPreferenceKeys.telemetryUsageData)
        TelemetryConsent.userChangedToggle(store: s)
        #expect(TelemetryConsent.state(store: s) == .init(crashes: true, performance: true, usage: true))
    }

    @Test("lifting the hold with crash reports off still sends no performance data")
    func holdLiftsCrashOff() throws {
        let s = try seeded(crash: true, usage: false)
        TelemetryConsent.migrate(store: s)
        s.set(false, forKey: PacerPreferenceKeys.telemetryCrashReports)
        TelemetryConsent.userChangedToggle(store: s)
        #expect(TelemetryConsent.state(store: s) == .init(crashes: false, performance: false, usage: false))
    }
}
