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
/// nothing while unused. Now at most one workspace a network is kept, at most
/// `keepBytes` of it: a call that needed more gives its large buffers back to
/// the system when it returns, and the next call allocates them at once at the
/// size they reached (`FMWorkspace`). `release()` frees the kept ones too (end
/// of a scoring pass, memory pressure).
public enum FMScratch {
    /// The largest workspace kept for the next call.
    nonisolated(unsafe) public static var keepBytes = 32 << 20
    /// Workspaces kept per network.
    nonisolated(unsafe) static var keepPerNetwork = 1
    /// A workspace over `keepBytes` keeps only its buffers up to this size.
    static let slotBytes = 2 << 20

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

    /// Each pool's network, calls, largest workspace and the calls that
    /// grew past `keepBytes` (probes).
    public static var stats: [(network: String, calls: Int, largest: Int, overCap: Int)] {
        pools.map { $0.stats }
    }
}

/// What `FMScratch` can ask of a pool.
protocol FMScratchPool: AnyObject, Sendable {
    var keptBytes: Int { get }
    var stats: (network: String, calls: Int, largest: Int, overCap: Int) { get }
    func trim()
}

/// A network's workspace: buffers grown on demand.
protocol FMWorkspaceBuffers: AnyObject {
    init()
    var bytes: Int { get }
    /// Free the buffers over `slotBytes`, remembering their size; returns
    /// whether any was freed.
    func shrink(above slotBytes: Int) -> Bool
}

/// One call's scratch buffers, one per slot, grown on demand
/// (Timestral, TimesFM and Chronos had three copies of this).
///
/// A slot freed by `shrink` remembers how large it was, and the next call
/// that needs it allocates it at that size at once. A fresh workspace grew a
/// long call's buffers in steps of half again, each step a new block whose
/// pages were faulted in again; on a pass where one network's weekly calls
/// needed 126 MB, dropping that workspace after each call made the whole
/// pass a third slower. An allocation's untouched pages cost nothing, so
/// asking for the remembered size up front costs only what the call uses.
final class FMWorkspace<Slot: CaseIterable & RawRepresentable>: FMWorkspaceBuffers where Slot.RawValue == Int {
    private var ptrs = [UnsafeMutablePointer<Float>?](repeating: nil, count: Slot.allCases.count)
    private var caps = [Int](repeating: 0, count: Slot.allCases.count)
    /// The capacity a freed slot had.
    private var remembered = [Int](repeating: 0, count: Slot.allCases.count)

    init() {}

    func buf(_ s: Slot, _ n: Int) -> UnsafeMutablePointer<Float> {
        let i = s.rawValue
        if caps[i] < n {
            ptrs[i]?.deallocate()
            let c = max(n, caps[i] * 3 / 2, remembered[i])
            ptrs[i] = .allocate(capacity: c)
            caps[i] = c
        }
        return ptrs[i]!
    }

    var bytes: Int { caps.reduce(0, +) * MemoryLayout<Float>.size }

    func shrink(above slotBytes: Int) -> Bool {
        var any = false
        for i in caps.indices where caps[i] * MemoryLayout<Float>.size > slotBytes {
            ptrs[i]?.deallocate()
            ptrs[i] = nil
            remembered[i] = max(remembered[i], caps[i])
            caps[i] = 0
            any = true
        }
        return any
    }

    deinit { for p in ptrs { p?.deallocate() } }
}

/// Workspaces for concurrent callers: one per call in flight, at most
/// `FMScratch.keepPerNetwork` kept, each under `FMScratch.keepBytes`.
final class FMWorkspacePool<W: FMWorkspaceBuffers>: FMScratchPool, @unchecked Sendable {
    private var free: [W] = []
    private let lock = NSLock()
    private var calls = 0, largest = 0, overCap = 0

    init() { FMScratch.register(self) }

    func with<T>(_ body: (W) throws -> T) rethrows -> T {
        lock.lock()
        let ws = free.popLast() ?? W()
        lock.unlock()
        defer {
            let bytes = ws.bytes
            FMScratch.noteSize(bytes)
            lock.lock()
            calls += 1
            largest = max(largest, bytes)
            if bytes > FMScratch.keepBytes { overCap += 1 }
            lock.unlock()
            // Over the cap: its large buffers go back to the system and the
            // small ones stay, with the large ones' sizes remembered.
            if bytes > FMScratch.keepBytes { _ = ws.shrink(above: FMScratch.slotBytes) }
            lock.lock()
            if free.count < FMScratch.keepPerNetwork, ws.bytes <= FMScratch.keepBytes { free.append(ws) }
            lock.unlock()
        }
        return try body(ws)
    }

    var keptBytes: Int { lock.lock(); defer { lock.unlock() }; return free.reduce(0) { $0 + $1.bytes } }

    var stats: (network: String, calls: Int, largest: Int, overCap: Int) {
        lock.lock(); defer { lock.unlock() }
        return (String(reflecting: W.self), calls, largest, overCap)
    }

    func trim() { lock.lock(); let gone = free; free = []; lock.unlock(); _ = gone }
}
