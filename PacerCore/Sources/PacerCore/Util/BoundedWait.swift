import Foundation

/// Waits for some work, but only so long.
///
/// For a shutdown step that must end in bounded time whatever the work it
/// waits on is doing (#446): a quit waits on the arena scorer, and on a
/// saturated Mac the scorer's background-QoS threads can go minutes without
/// a core.
public enum BoundedWait {
    /// Runs `work` in a task of its own, at the caller's priority, and waits
    /// for it for at most `bound` of wall time. Returns whether it finished.
    ///
    /// The work is not cancelled at the bound, only no longer waited for:
    /// what it does after that is up to it (at a quit, the process ends
    /// under it). The bound's own wait is a task at the caller's priority on
    /// the shared pool, so it is never one of the threads the work is waiting
    /// on.
    public static func atMost(_ bound: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let first = FirstAnswer()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            first.arm(c)
            let timer = Task {
                try? await Task.sleep(for: bound)
                first.answer(false)
            }
            Task {
                await work()
                first.answer(true)
                timer.cancel()
            }
        }
    }

    /// The first of two answers, once.
    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func arm(_ c: CheckedContinuation<Bool, Never>) {
            lock.lock(); continuation = c; lock.unlock()
        }

        func answer(_ value: Bool) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}
