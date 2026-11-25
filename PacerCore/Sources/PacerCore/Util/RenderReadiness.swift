import Foundation

/// Which off-main loads a view has started and not yet finished, so the
/// off-screen renderer captures when they are done rather than after a guess.
///
/// **Why**: `OffscreenRenderer` used to wait a fixed time, and a view whose
/// value comes from a detached read (History's PROJECTS count) rendered its
/// loading placeholder whenever the runner was slow enough (#452). A fixed
/// wait cannot be right on a loaded machine; a count of loads in flight can.
///
/// Only the screenshot and live-render launch modes track anything. In the
/// user's app `RenderReadiness.task` is exactly `Task.detached`: no counter,
/// no hop back to the main actor, no allocation.
@MainActor
public final class RenderReadinessTracker {
    public let isEnabled: Bool
    private var pending: [Int: String] = [:]
    private var nextToken = 0

    public init(isEnabled: Bool) { self.isEnabled = isEnabled }

    /// A load started. Returns the token to hand to `end`.
    public func begin(_ label: String) -> Int {
        nextToken += 1
        pending[nextToken] = label
        return nextToken
    }

    public func end(_ token: Int) { pending[token] = nil }

    /// Labels of the loads still running, sorted.
    public var pendingLabels: [String] { pending.values.sorted() }

    public enum Outcome: Equatable, Sendable {
        case idle
        /// The timeout passed with these loads still running.
        case timedOut(pending: [String])
    }

    /// Returns once no load has been in flight for `quiet`, or after `timeout`.
    ///
    /// `quiet` and not merely "zero now": a finished load's result is applied
    /// by the view a main-actor turn later, and applying it can start the next
    /// load (History re-runs its read when its inputs changed meanwhile).
    public func waitUntilIdle(
        timeout: Duration, quiet: Duration = .milliseconds(300),
        poll: Duration = .milliseconds(50)
    ) async -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var idleSince: ContinuousClock.Instant? = pending.isEmpty ? clock.now : nil
        while true {
            if pending.isEmpty {
                let since = idleSince ?? clock.now
                idleSince = since
                if clock.now - since >= quiet { return .idle }
            } else {
                idleSince = nil
            }
            if clock.now >= deadline { return pending.isEmpty ? .idle : .timedOut(pending: pendingLabels) }
            try? await Task.sleep(for: poll)
        }
    }
}

@MainActor
public enum RenderReadiness {
    public static let shared = RenderReadinessTracker(
        isEnabled: LaunchMode.isActive(.screenshot) || LaunchMode.isActive(.liveRender))

    /// `Task.detached`, counted while a render is waiting on it. Call from the
    /// main actor (where a view starts its load); `.value` is awaited as usual.
    public static func task<T: Sendable>(
        _ label: String, priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> T
    ) -> Task<T, Never> {
        guard shared.isEnabled else { return Task.detached(priority: priority, operation: operation) }
        let token = shared.begin(label)
        return Task.detached(priority: priority) {
            let result = await operation()
            await MainActor.run { shared.end(token) }
            return result
        }
    }
}
