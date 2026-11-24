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
public enum BackgroundQoS {
    /// The lowest class applied in this process.
    static let floor: qos_class_t = PacerPreferences.isTestProcess ? QOS_CLASS_UTILITY : QOS_CLASS_BACKGROUND

    /// `qos`, or the floor when that is higher.
    public static func applied(_ qos: qos_class_t) -> qos_class_t {
        qos.rawValue < floor.rawValue ? floor : qos
    }

    /// For a dispatch queue that would run at background.
    public static var queue: DispatchQoS {
        DispatchQoS(qosClass: DispatchQoS.QoSClass(rawValue: floor) ?? .background, relativePriority: 0)
    }

    /// For a task that would run at background priority.
    public static var priority: TaskPriority { TaskPriority(rawValue: UInt8(floor.rawValue)) }
}
