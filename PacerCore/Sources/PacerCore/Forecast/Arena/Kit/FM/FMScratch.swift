import Foundation

/// The networks' scratch buffers (activations, attention scores, a decoder's
/// KV cache), shared by Timestral, TimesFM and Chronos.
///
/// Each call takes a workspace from its network's pool, grows its buffers to
/// the call's size and gives it back. The first pools kept up to four per
/// network, each at the largest size any call had needed: with six networks,
/// a long weekly context and the scorer and the live forecaster calling the
/// same network at once, that was hundreds of megabytes of dirty memory held
/// for good, against the 1–3 GB of weights that are mapped from disk and cost
/// nothing while unused. Now at most one workspace a network is kept, and
/// only one under `keepBytes`: a large one is freed when its call returns
/// (large blocks go straight back to the system), which costs the next call a
/// few milliseconds of page faults against forecasts of hundreds. `release()`
/// frees the kept ones too (end of a scoring pass, memory pressure).
public enum FMScratch {
    /// The largest workspace kept for the next call.
    nonisolated(unsafe) public static var keepBytes = 16 << 20
    /// Workspaces kept per network.
    nonisolated(unsafe) static var keepPerNetwork = 1

    private static let registry = Registry()

    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var pools: [WeakPool] = []
        var largest = 0
    }

    struct WeakPool { weak var pool: (any FMScratchPool)? }

    static func register(_ pool: any FMScratchPool) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.pools.removeAll { $0.pool == nil }
        registry.pools.append(WeakPool(pool: pool))
    }

    static func noteSize(_ bytes: Int) {
        registry.lock.lock(); registry.largest = max(registry.largest, bytes); registry.lock.unlock()
    }

    private static var pools: [any FMScratchPool] {
        registry.lock.lock(); defer { registry.lock.unlock() }
        return registry.pools.compactMap(\.pool)
    }

    /// Bytes held by kept (idle) workspaces, every network.
    public static var keptBytes: Int { pools.reduce(0) { $0 + $1.keptBytes } }

    /// The largest workspace any call has needed in this process.
    public static var largestBytes: Int {
        registry.lock.lock(); defer { registry.lock.unlock() }
        return registry.largest
    }

    /// Free every kept workspace; the next call of each network makes one.
    public static func release() { pools.forEach { $0.trim() } }
}

/// What `FMScratch` can ask of a pool.
protocol FMScratchPool: AnyObject, Sendable {
    var keptBytes: Int { get }
    func trim()
}

/// A network's workspace: buffers grown on demand.
protocol FMWorkspaceBuffers: AnyObject {
    init()
    var bytes: Int { get }
}

/// Workspaces for concurrent callers: one per call in flight, at most
/// `FMScratch.keepPerNetwork` kept, each under `FMScratch.keepBytes`.
final class FMWorkspacePool<W: FMWorkspaceBuffers>: FMScratchPool, @unchecked Sendable {
    private var free: [W] = []
    private let lock = NSLock()

    init() { FMScratch.register(self) }

    func with<T>(_ body: (W) throws -> T) rethrows -> T {
        lock.lock()
        let ws = free.popLast() ?? W()
        lock.unlock()
        defer {
            let bytes = ws.bytes
            FMScratch.noteSize(bytes)
            lock.lock()
            if free.count < FMScratch.keepPerNetwork, bytes <= FMScratch.keepBytes { free.append(ws) }
            lock.unlock()
        }
        return try body(ws)
    }

    var keptBytes: Int { lock.lock(); defer { lock.unlock() }; return free.reduce(0) { $0 + $1.bytes } }

    func trim() { lock.lock(); let gone = free; free = []; lock.unlock(); _ = gone }
}
