import Foundation

/// When the grader starts on a launch: as soon as launch's own work is done,
/// not after a fixed wait. The first pass reads months of limits and turns for
/// every account, and each thing launch does on the same store (an upgrade's
/// first scan can be minutes of rebuilding, #326) would only be slower for it;
/// a Mac with a quiet launch, on the other hand, has no reason to wait at all.
///
/// A signal that never comes must not hold the grader back for good: after
/// `safetyNet` it starts anyway, and the log says what it was still waiting
/// for. While it waits the account has no pass and no grade, which is what
/// the board's "Waiting to score your history" says.
public final class ArenaStartGate: @unchecked Sendable {
    public enum Signal: String, CaseIterable, Sendable {
        /// The store is open (`StoreLoader`).
        case store
        /// The scan loop's first cycle has ended, any rebuild in it included.
        case firstScan = "first scan"
        /// The engines' first refit has ended.
        case firstRefit = "first refit"
        /// The engines' record backfill has ended.
        case recordBackfill = "record backfill"
    }

    /// Longer than launch work should take (an upgrade's first scan is minutes
    /// of CPU, #326), and what a signal that never comes costs: the grader
    /// starting half an hour late.
    public static let safetyNet: TimeInterval = 30 * 60

    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let began: Date
    private let lock = NSLock()
    // Guarded by `lock`.
    private var start: (@Sendable () -> Void)?
    private var marked: [Signal: Date] = [:]
    private var net: Task<Void, Never>?

    /// - Parameter start: called once, off any thread, when the gate opens;
    ///   never after `cancel`.
    public init(now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { Log.write("Arena", $0) },
                start: @escaping @Sendable () -> Void) {
        self.now = now; self.log = log; self.start = start
        began = now()
    }

    /// Start the safety net's clock.
    public func armSafetyNet(after seconds: TimeInterval = safetyNet) {
        let task = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.giveUp()
        }
        lock.lock(); net = task; lock.unlock()
    }

    /// `signal` has happened. The last of them opens the gate.
    public func mark(_ signal: Signal) {
        lock.lock()
        if marked[signal] == nil { marked[signal] = now() }
        let done = Signal.allCases.allSatisfy { marked[$0] != nil }
        lock.unlock()
        if done { open(reason: "launch work done") }
    }

    /// The safety net ran out: open, saying what never came.
    public func giveUp() {
        lock.lock()
        let missing = Signal.allCases.filter { marked[$0] == nil }.map(\.rawValue)
        lock.unlock()
        open(reason: "still waiting for \(missing.joined(separator: ", "))")
    }

    /// The app is stopping: the gate never opens.
    public func cancel() {
        lock.lock()
        start = nil
        let task = net
        net = nil
        lock.unlock()
        task?.cancel()
    }

    /// What the log says about each signal, seconds after the gate was made.
    private func timings() -> String {
        Signal.allCases.compactMap { s in
            marked[s].map { String(format: "%@ %.1f s", s.rawValue, $0.timeIntervalSince(began)) }
        }.joined(separator: ", ")
    }

    private func open(reason: String) {
        lock.lock()
        guard let go = start else { lock.unlock(); return }
        start = nil
        let task = net
        net = nil
        let line = String(format: "grader starting after %.1f s, %@", now().timeIntervalSince(began), reason)
            + (marked.isEmpty ? "" : " (\(timings()))")
        lock.unlock()
        task?.cancel()
        log(line)
        go()
    }
}
