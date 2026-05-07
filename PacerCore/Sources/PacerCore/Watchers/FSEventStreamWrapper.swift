import Foundation
@preconcurrency import CoreServices

/// Thin Swift wrapper around CoreServices' `FSEventStreamCreate` C API.
/// Owns the raw stream handle, schedules it on a dedicated dispatch
/// queue, and forwards events to a Swift closure.
///
/// `@unchecked Sendable`: the wrapper is mutated from one place (the
/// queue's callback context) and read from one place (the owning
/// `JSONLWatcher` actor). Cross-queue safety comes from our discipline,
/// not the type system — same pattern used everywhere FSEventStream
/// shows up in Swift.
public final class FSEventStreamWrapper: @unchecked Sendable {

    public typealias EventHandler = @Sendable (_ paths: [String]) -> Void

    private let queue: DispatchQueue
    private let handler: EventHandler
    /// FSEventStreamRef is an opaque CoreFoundation type. Storing it
    /// behind `Unmanaged` would mean manual retain/release; the simpler
    /// thing is to keep it as the documented opaque type and rely on
    /// `FSEventStreamRelease` in `stop()`.
    private var stream: FSEventStreamRef?

    public init(handler: @escaping EventHandler, queueLabel: String = "com.ericandrechek.pacer.fsevents") {
        self.handler = handler
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    deinit {
        // Defensive: if the owner forgot to call stop(), make sure the
        // FSEventStream is invalidated and freed.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Begin watching `paths` recursively. Idempotent: a second `start`
    /// stops the existing stream first. Returns `true` if the stream
    /// successfully started, `false` if the OS rejected it (e.g.
    /// permission denied on every path).
    @discardableResult
    public func start(
        paths: [String],
        latencySeconds: CFTimeInterval = 0.5
    ) -> Bool {
        stop()
        guard !paths.isEmpty else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Flags:
        //   - UseCFTypes: receive event paths as CFArray<CFString>
        //     in the callback, not the legacy `char**`. Without this,
        //     FSEvents passes raw C strings — a Swift `NSArray` cast
        //     compiles fine but crashes inside fast-enumeration.
        //     Tests use `.manual` mode so this only surfaced when the
        //     real daemon ran on live files. (Documented behavior;
        //     `unsafeBitCast(rawPointer, to: NSArray.self)` requires
        //     this flag.)
        //   - FileEvents: get per-file events, not coarse per-directory.
        //     Required because Claude Code writes JSONL line-by-line and
        //     we want to know which transcript changed, not just "the
        //     projects tree."
        //   - NoDefer: fire immediately on the first event in a batch
        //     instead of waiting `latencySeconds`. Combined with a small
        //     latency this gives us sub-second reactivity on the first
        //     write, then coalesces the rest. Subsequent burst writes
        //     within the latency window are batched into one callback.
        //   - WatchRoot: notify if the watched root itself moves or is
        //     deleted. Cheap insurance against `~/.claude/projects/`
        //     getting renamed out from under us.
        let flags: UInt32 = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latencySeconds,
            flags
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(s, queue)
        let started = FSEventStreamStart(s)
        if !started {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        self.stream = s
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    // The C callback. Cannot capture `self` (must be a plain function
    // pointer), so we round-trip through `clientCallBackInfo` which
    // we set to `Unmanaged.passUnretained(self).toOpaque()` in start().
    private static let eventCallback: FSEventStreamCallback = {
        _, info, numEvents, eventPathsPointer, _, _ in
        guard let info else { return }
        let wrapper = Unmanaged<FSEventStreamWrapper>.fromOpaque(info).takeUnretainedValue()
        // FSEvents passes paths as a CFArray of CFStrings (in
        // FileEvents mode). The underlying NSArray bridges to [String].
        let paths = unsafeBitCast(eventPathsPointer, to: NSArray.self)
        var collected: [String] = []
        collected.reserveCapacity(numEvents)
        for case let path as String in paths {
            collected.append(path)
        }
        wrapper.handler(collected)
    }
}
