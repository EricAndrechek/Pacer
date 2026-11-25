import Foundation
import Synchronization

/// Which off-main loads a view has started and not yet finished, so the
/// off-screen renderer captures when they are done rather than after a guess.
///
/// **Why**: `OffscreenRenderer` used to wait a fixed time, and a view whose
/// value comes from a detached read (History's PROJECTS count) rendered its
/// loading placeholder whenever the runner was slow enough (#452). A fixed
/// wait cannot be right on a loaded machine; a count of loads in flight can.
///
/// **No actor.** `askEngine` is nonisolated and must not hop to the main actor
/// just to start a task, so the counter is a lock, `begin`/`end` are
/// synchronous, and a finished load is never "queued" behind a busy main
/// thread. Only the screenshot and live-render launch modes count anything: in
/// the user's app `RenderReadiness.task` is exactly `Task.detached`.
public final class RenderReadinessTracker: Sendable {
    public let isEnabled: Bool
    private struct State { var pending: [Int: String] = [:]; var next = 0 }
    private let state = Mutex(State())

    public init(isEnabled: Bool) { self.isEnabled = isEnabled }

    /// A load started. Returns the token to hand to `end`.
    public func begin(_ label: String) -> Int {
        state.withLock { s in
            s.next += 1
            s.pending[s.next] = label
            return s.next
        }
    }

    public func end(_ token: Int) { state.withLock { $0.pending[token] = nil } }

    /// Labels of the loads still running, sorted.
    public var pendingLabels: [String] { state.withLock { $0.pending.values.sorted() } }

    /// `Task.detached`, counted while a render waits on it. Disabled: plain
    /// `Task.detached`, no lock, no extra hop.
    public func task<T: Sendable>(
        _ label: String, priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> T
    ) -> Task<T, Never> {
        guard isEnabled else { return Task.detached(priority: priority, operation: operation) }
        let token = begin(label)
        return Task.detached(priority: priority) { [self] in
            let result = await operation()
            end(token)
            return result
        }
    }

    public enum Outcome: Equatable, Sendable {
        case idle
        /// The timeout passed with these loads still running.
        case timedOut(pending: [String])
    }

    /// Returns once no load has been in flight for `quiet`, or after `timeout`.
    ///
    /// `quiet` and not merely "zero now": a finished load's result is applied
    /// by the view a turn later, and applying it can start the next load
    /// (History re-runs its read when its inputs changed meanwhile).
    public func waitUntilIdle(
        timeout: Duration, quiet: Duration = .milliseconds(500),
        poll: Duration = .milliseconds(50)
    ) async -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var idleSince: ContinuousClock.Instant?
        while true {
            if pendingLabels.isEmpty {
                let since = idleSince ?? clock.now
                idleSince = since
                if clock.now - since >= quiet { return .idle }
            } else {
                idleSince = nil
            }
            if clock.now >= deadline {
                // Re-check after a yield: a stall that ate the deadline must
                // not report loads that have finished since.
                await Task.yield()
                let left = pendingLabels
                return left.isEmpty ? .idle : .timedOut(pending: left)
            }
            try? await Task.sleep(for: poll)
        }
    }
}

public enum RenderReadiness {
    /// Fixed at launch by `LaunchMode`.
    public static let isEnabled = LaunchMode.isActive(.screenshot) || LaunchMode.isActive(.liveRender)
    public static let shared = RenderReadinessTracker(isEnabled: isEnabled)

    public static func task<T: Sendable>(
        _ label: String, priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> T
    ) -> Task<T, Never> {
        shared.task(label, priority: priority, operation: operation)
    }
}
