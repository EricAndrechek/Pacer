import Darwin
import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// #431: in a test process nothing the arena applies runs at background QoS,
/// which a saturated Mac does not schedule at all; the policies that choose a
/// class still choose background.
@Suite("Background QoS in a test process (#431)", .serialized, .hangBackstop)
struct BackgroundQoSTests {

    static let every = [QOS_CLASS_BACKGROUND, QOS_CLASS_UTILITY, QOS_CLASS_DEFAULT, QOS_CLASS_USER_INITIATED,
                        QOS_CLASS_USER_INTERACTIVE]

    /// The app's branch: every class applied exactly as asked, background
    /// included. Decided once per process, so a test only ever sees its own
    /// branch; this is the one that ships.
    @Test func theAppAppliesEveryClassAsAsked() {
        let app = BackgroundQoS.floor(isTestProcess: false, environment: [:])
        #expect(app == QOS_CLASS_BACKGROUND)
        for q in Self.every { #expect(BackgroundQoS.applied(q, floor: app) == q) }
        #expect(BackgroundQoS.queue(floor: app) == .background)
        #expect(BackgroundQoS.priority(floor: app) == .background)
        // An app launch with the probes' variable set is the app all the same.
        #expect(BackgroundQoS.floor(isTestProcess: false, environment: ["PACER_PRODUCTION_QOS": "1"])
                == QOS_CLASS_BACKGROUND)
    }

    /// A test process that asks for the app's classes (the opt-in probes) gets
    /// them; any other value of the variable is a test process as usual.
    @Test func theProbesCanAskForTheAppsClasses() {
        #expect(BackgroundQoS.floor(isTestProcess: true, environment: ["PACER_PRODUCTION_QOS": "1"])
                == QOS_CLASS_BACKGROUND)
        #expect(BackgroundQoS.floor(isTestProcess: true, environment: ["PACER_PRODUCTION_QOS": "0"])
                == QOS_CLASS_UTILITY)
        #expect(BackgroundQoS.floor(isTestProcess: true, environment: [:]) == QOS_CLASS_UTILITY)
    }

    @Test func backgroundIsAppliedAsUtilityAndNothingHigherIsTouched() {
        #expect(PacerPreferences.isTestProcess)
        // This run is the test branch unless it asked for the app's classes.
        guard ProcessInfo.processInfo.environment["PACER_PRODUCTION_QOS"] != "1" else { return }
        #expect(BackgroundQoS.applied(QOS_CLASS_BACKGROUND) == QOS_CLASS_UTILITY)
        #expect(BackgroundQoS.applied(QOS_CLASS_UTILITY) == QOS_CLASS_UTILITY)
        #expect(BackgroundQoS.applied(QOS_CLASS_DEFAULT) == QOS_CLASS_DEFAULT)
        #expect(BackgroundQoS.applied(QOS_CLASS_USER_INITIATED) == QOS_CLASS_USER_INITIATED)
        #expect(BackgroundQoS.priority == .utility)
        #expect(BackgroundQoS.queue == .utility)
        // What chooses the class is the app's policy, unchanged.
        #expect(ArenaCPUBudget(rate: 0.2).scorerQoS == QOS_CLASS_BACKGROUND)
        #expect(ArenaBudgetPolicy.scorerQoS(.share(.lowMemory), spedUp: false) == QOS_CLASS_BACKGROUND)
    }

    /// The QoS class of every thread a forecast ran on.
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var classes: [qos_class_t] = []
        func note() { let q = qos_class_self(); lock.withLock { classes.append(q) } }
        var all: [qos_class_t] { lock.withLock { classes } }
    }
    static let seen = Seen()

    final class Noting: ArenaModel {
        let inner: RuntimeEngineTests.Peeker
        init(context: ArenaContext) { inner = RuntimeEngineTests.Peeker(context: context) }
        func fit(_ history: ArenaHistory) { inner.fit(history) }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            BackgroundQoSTests.seen.note()
            return try inner.forecast(request)
        }
    }

    /// The scorer's workers, at the everyday share (background in the app),
    /// forecast at utility here: the threads `sample` found runnable and never
    /// run in #431.
    @Test func theScorersWorkersRunAtUtility() async throws {
        guard ProcessInfo.processInfo.environment["PACER_PRODUCTION_QOS"] != "1" else { return }
        let container = try RuntimeEngineTests.seeded(cycles: 4)
        let spec = ArenaModelSpec(name: "test-qos-noting", targets: RuntimeEngineTests.meters) { Noting(context: $0) }
        var config = RuntimeEngineTests.noSleep()
        config.adaptiveBudget = false
        let rt = RuntimeEngineTests.runtime(container, roster: [spec], config: config)
        #expect(rt.budget.scorerQoS == QOS_CLASS_BACKGROUND)
        let report = await rt.scorer.pass(accounts: [RuntimeEngineTests.account], now: RuntimeEngineTests.now)
        #expect(report.forecasts > 0)
        let classes = Self.seen.all
        #expect(!classes.isEmpty)
        #expect(classes.allSatisfy { $0 == QOS_CLASS_UTILITY }, "forecast QoS classes: \(Set(classes.map(\.rawValue)))")
    }
}
