import Darwin
import Foundation

/// The background QoS class, as it is applied: background in the app, utility
/// in a test process.
///
/// In the app background is the point. The arena's back-scoring, its history
/// builds and the record's clean-up are work nothing waits on, and the lowest
/// tier macOS has runs them when nothing else wants the cores. A test does
/// wait on them, and a saturated Mac gives that tier nothing at all: on
/// 2026-11-24, at a load average over 100 from other builds, four scorer
/// workers of a test sat runnable at priority 4 with 0.0% CPU for minutes
/// (`ps -M`), `sample` showing every one of them mid-forecast in user code,
/// blocked on nothing. That is what #431's two "hangs at 0% CPU" were, in
/// `ArenaScoringCrew` and in `deletePreviousGradings`: no deadlock, a test
/// waiting on threads the scheduler would not run.
///
/// Utility is the class the arena's live lane already runs at, still below the
/// test's own, and out of the background tier. Only where a class is *applied*
/// goes through here (a queue, a task, a thread): the policy that chooses one
/// (`ArenaBudgetPolicy.scorerQoS`) still answers background, and its tests
/// still say so. The same reasoning, and the same switch, as
/// `MemoryPressure.shared`: what a test sees must not depend on what else the
/// Mac is doing.
///
/// `PACER_PRODUCTION_QOS=1` keeps the app's classes in a test process, for the
/// opt-in probes that measure what the app does (`RuntimePerfProbe`,
/// `RuntimeMemoryProbe`, `RealStoreMemoryProbe`).
public enum BackgroundQoS {
    /// The lowest class this process applies: background, but utility in a
    /// test process that has not asked for the app's classes. Pure, so both
    /// answers are tested; `floor` is this process's.
    static func floor(isTestProcess: Bool, environment: [String: String]) -> qos_class_t {
        isTestProcess && environment["PACER_PRODUCTION_QOS"] != "1" ? QOS_CLASS_UTILITY : QOS_CLASS_BACKGROUND
    }

    /// This process's floor, decided once.
    static let floor = Self.floor(isTestProcess: PacerPreferences.isTestProcess,
                                  environment: ProcessInfo.processInfo.environment)

    /// `qos`, or `floor` when that is higher.
    static func applied(_ qos: qos_class_t, floor: qos_class_t) -> qos_class_t {
        qos.rawValue < floor.rawValue ? floor : qos
    }

    static func queue(floor: qos_class_t) -> DispatchQoS {
        DispatchQoS(qosClass: DispatchQoS.QoSClass(rawValue: floor) ?? .background, relativePriority: 0)
    }

    static func priority(floor: qos_class_t) -> TaskPriority { TaskPriority(rawValue: UInt8(floor.rawValue)) }

    /// `qos` as this process applies it.
    public static func applied(_ qos: qos_class_t) -> qos_class_t { applied(qos, floor: Self.floor) }

    /// For a dispatch queue that would run at background.
    public static var queue: DispatchQoS { queue(floor: Self.floor) }

    /// For a task that would run at background priority.
    public static var priority: TaskPriority { priority(floor: Self.floor) }
}
