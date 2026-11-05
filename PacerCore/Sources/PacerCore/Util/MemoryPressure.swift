import Darwin
import Foundation

/// How short of memory macOS says this Mac is, for work that can wait.
///
/// The kernel's own verdict, not a reading of "free" memory: macOS keeps free
/// memory low on purpose (a healthy Mac often shows a few hundred MB free, the
/// rest being file cache and compressed pages), so a free-memory threshold
/// would call most Macs starved. `.warning` and `.critical` are what the system
/// itself means by pressure, and they arrive as dispatch events.
///
/// Read `level` from any thread. A source only reports changes, so the current
/// level is seeded from `kern.memorystatus_vm_pressure_level` at creation.
public final class MemoryPressure: @unchecked Sendable {
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case normal = 0, warning, critical

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        /// The name for logs and telemetry.
        public var name: String {
            switch self {
            case .normal: return "normal"
            case .warning: return "warning"
            case .critical: return "critical"
            }
        }
    }

    public static let shared = MemoryPressure(watching: true)

    private let lock = NSLock()
    // Guarded by `lock`.
    private var current: Level
    private var listeners: [UUID: @Sendable (Level) -> Void] = [:]
    private var source: DispatchSourceMemoryPressure?

    /// - Parameter watching: false for a test, which drives it with `set`.
    public init(watching: Bool = false) {
        current = watching ? Self.kernelLevel() : .normal
        guard watching else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                             queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.set(event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal)
        }
        self.source = source
        source.activate()
    }

    deinit { source?.cancel() }

    /// The level now.
    public var level: Level { lock.lock(); defer { lock.unlock() }; return current }

    /// Apply a level, telling listeners when it changed.
    public func set(_ next: Level) {
        lock.lock()
        guard next != current else { lock.unlock(); return }
        current = next
        let wake = Array(listeners.values)
        lock.unlock()
        wake.forEach { $0(next) }
    }

    /// Called on an unspecified thread whenever the level changes.
    @discardableResult
    public func listen(_ handler: @escaping @Sendable (Level) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = handler; lock.unlock()
        return id
    }

    public func unlisten(_ id: UUID) { lock.lock(); listeners[id] = nil; lock.unlock() }

    /// The kernel's current level: 1 normal, 2 warning, 4 critical. Anything
    /// unreadable counts as normal, so a failed read never holds work back.
    static func kernelLevel() -> Level {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .normal }
        return value >= 4 ? .critical : value >= 2 ? .warning : .normal
    }
}
