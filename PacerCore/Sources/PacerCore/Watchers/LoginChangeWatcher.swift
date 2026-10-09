import Foundation

/// Tells the scan coordinator the moment the login changes, instead of letting
/// it find out on its next scan cycle (#192).
///
/// A login switch was only noticed when a cycle ran, and cycles run on
/// transcript activity or a 5-minute backstop, so a switch on a quiet machine
/// could sit unseen for minutes and even a busy one took seconds. Three files
/// move when the login does, and each is watched with a kqueue vnode source:
///
/// - **Claude Code's global config** (`~/.claude.json`, or the one the
///   attribution trail reads under `CLAUDE_CONFIG_DIR`). Rewritten every
///   5–15 s while Claude Code runs, so every rewrite is filtered through
///   `ConfigLoginIdentity` — a scan for one ~200-byte object — and only a
///   different `oauthAccount` is passed on.
/// - **The login keychain file.** Written by any app that stores anything, so
///   a write is filtered through `KeychainItemStamp`: the `Claude
///   Code-credentials` item's modification date, read without its secret.
///   Only a moved stamp is passed on. This is what catches cswap, which
///   rewrites the item.
/// - **cswap's usage cache.** Its roster names accounts Pacer has never
///   polled, and its readings are often there before Pacer has a lane for a
///   new token. Every change is passed on: the ingest it triggers is
///   idempotent per reading.
///
/// What a signal *means* is decided elsewhere: the coordinator re-reads the
/// credential and lets the trail judge, with the stale-config veto intact.
/// This only says "look now".
///
/// **Debounced** per file, trailing edge: an atomic replace is a burst of
/// directory and file events, and one look after it settles is enough. All
/// work runs on one utility queue of its own; nothing here touches the store
/// or any actor.
public final class LoginChangeWatcher: @unchecked Sendable {

    public enum Signal: String, Sendable {
        case config
        case keychain
        case switcher
    }

    /// Settle time after the last event on a file before it is looked at.
    static let debounce: DispatchTimeInterval = .milliseconds(150)

    private let queue = DispatchQueue(label: "com.ericandrechek.pacer.loginwatch", qos: .utility)
    private let configCandidates: [URL]
    private let keychainFile: URL?
    private let switcherCache: URL?
    private let keychainStamp: @Sendable () -> String?
    private let onSignal: @Sendable (Signal, Date) -> Void

    // Queue-confined.
    private var sources: [FileChangeSource] = []
    private var lastIdentity: ConfigLoginIdentity?
    private var lastStamp: String?
    private var lastStampAt: Date?
    private var deferredStampCheck: DispatchWorkItem?

    /// Floor between two keychain attribute queries (each is a `security`
    /// subprocess, ~10–20 ms).
    static let keychainMinimumSpacing: TimeInterval = 1

    /// - Parameters:
    ///   - configCandidates: the config paths the trail resolves, most
    ///     specific first; the first that exists is the login.
    ///   - keychainFile, switcherCache: nil leaves that source unwatched.
    ///   - keychainStamp: injected so a test never asks the machine's keychain.
    public init(
        configCandidates: [URL],
        keychainFile: URL?,
        switcherCache: URL?,
        keychainStamp: @escaping @Sendable () -> String? = { KeychainItemStamp.current() },
        onSignal: @escaping @Sendable (Signal, Date) -> Void
    ) {
        self.configCandidates = configCandidates
        self.keychainFile = keychainFile
        self.switcherCache = switcherCache
        self.keychainStamp = keychainStamp
        self.onSignal = onSignal
    }

    /// `~/Library/Keychains/login.keychain-db`.
    public static func defaultKeychainFile(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Keychains")
            .appendingPathComponent("login.keychain-db")
    }

    /// Take the baselines, then arm the sources. Baselines first, so the
    /// first event compares against what was there at launch rather than
    /// reporting it as a change.
    public func start() {
        queue.async { [self] in
            guard sources.isEmpty else { return }
            lastIdentity = currentIdentity()
            var made: [FileChangeSource] = []
            var watching = ["config"]
            for candidate in configCandidates {
                made.append(FileChangeSource(url: candidate, queue: queue, debounce: Self.debounce) {
                    [weak self] in self?.configMayHaveChanged()
                })
            }
            if let keychainFile {
                lastStamp = keychainStamp()
                // Every write to the file itself, not only one that moved its
                // signature: how the keychain daemon writes it is not ours to
                // know, and the stamp query is the real filter. Directory
                // events still need a moved signature, so a lock file coming
                // and going beside it — which a read might cause — is ignored.
                made.append(FileChangeSource(url: keychainFile, queue: queue, debounce: Self.debounce,
                                             reportsEveryEvent: true) {
                    [weak self] in self?.keychainMayHaveChanged()
                })
                watching.append("keychain item")
            }
            if let switcherCache {
                made.append(FileChangeSource(url: switcherCache, queue: queue, debounce: Self.debounce) {
                    [weak self] in self?.emit(.switcher, detail: nil)
                })
                watching.append("cswap cache")
            }
            sources = made
            for source in sources { source.start() }
            Log.write("LoginWatch", "watching the login: \(watching.joined(separator: ", "))")
        }
    }

    public func stop() {
        queue.async { [self] in
            for source in sources { source.cancel() }
            sources = []
            deferredStampCheck?.cancel()
            deferredStampCheck = nil
        }
    }

    // MARK: - Filters (on `queue`)

    private func currentIdentity() -> ConfigLoginIdentity? {
        let fm = FileManager.default
        guard let url = configCandidates.first(where: { fm.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return ConfigLoginIdentity.extract(from: data)
    }

    private func configMayHaveChanged() {
        // nil is "can't tell" — logged out, or caught mid-write. It never
        // replaces a known identity, so the next real read compares against
        // the last login rather than reporting it as new. A login after a
        // launch that found none is a change like any other.
        guard let identity = currentIdentity(), identity != lastIdentity else { return }
        let previous = lastIdentity
        lastIdentity = identity
        emit(.config, detail: "config names \(identity.organizationId?.prefix(4) ?? "?")"
                + " (was \(previous?.organizationId?.prefix(4) ?? "none"))")
    }

    private func keychainMayHaveChanged() {
        // At most one attribute query a second, however busy the keychain
        // file is: a deferred look covers whatever arrives in between.
        let now = Date()
        if let last = lastStampAt, now.timeIntervalSince(last) < Self.keychainMinimumSpacing {
            guard deferredStampCheck == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.deferredStampCheck = nil
                self?.keychainMayHaveChanged()
            }
            deferredStampCheck = work
            queue.asyncAfter(
                deadline: .now() + Self.keychainMinimumSpacing - now.timeIntervalSince(last),
                execute: work)
            return
        }
        lastStampAt = now
        guard let stamp = keychainStamp(), stamp != lastStamp else { return }
        lastStamp = stamp
        emit(.keychain, detail: "Claude Code credential rewritten")
    }

    /// `detail` nil for cswap's cache, which cswap rewrites on every poll of
    /// every account: one line per write would be most of the log. The poller
    /// says when an ingest did something (a new account, a reading).
    private func emit(_ signal: Signal, detail: String?) {
        let seen = Date()
        if let detail { Log.write("LoginWatch", "\(detail) — \(signal.rawValue) change seen") }
        onSignal(signal, seen)
    }
}

/// A kqueue watch on one file that survives the file being replaced.
///
/// Two sources: one on the file's own vnode (an in-place write, a delete, a
/// rename away), one on its directory (a new file renamed into place, which
/// is how an atomic save lands and how a file that did not exist yet
/// appears). Either one makes it look again; it reports only when the file's
/// identity, size or modification time actually differ from the last look,
/// so a directory busy with other files costs a `stat` per event and nothing
/// more — unless `reportsEveryEvent`, for a handler that is its own filter,
/// and then only for writes to the file itself.
///
/// A directory that does not exist yet (cswap not installed) is retried once
/// a minute — one `open` attempt, no reads.
final class FileChangeSource: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    /// Report every settled burst of events on the file's own vnode rather
    /// than only a changed signature — for a file whose writer's habits are
    /// unknown and whose handler is its own filter. Directory events are
    /// always filtered by signature.
    private let reportsEveryEvent: Bool
    /// A file-vnode event arrived in the burst being debounced.
    private var pendingFileEvent = false
    private let handler: () -> Void

    // Queue-confined.
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var retryTimer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var signature: Signature?
    private var cancelled = false

    private struct Signature: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: timespec

        static func == (l: Signature, r: Signature) -> Bool {
            l.inode == r.inode && l.size == r.size
                && l.modified.tv_sec == r.modified.tv_sec && l.modified.tv_nsec == r.modified.tv_nsec
        }
    }

    init(url: URL, queue: DispatchQueue, debounce: DispatchTimeInterval,
         reportsEveryEvent: Bool = false, handler: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.reportsEveryEvent = reportsEveryEvent
        self.handler = handler
    }

    /// Call on `queue`.
    func start() {
        signature = currentSignature()
        armDirectory()
        armFile()
    }

    /// Call on `queue`.
    func cancel() {
        cancelled = true
        pending?.cancel()
        pending = nil
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
        retryTimer?.cancel()
        retryTimer = nil
    }

    private func currentSignature() -> Signature? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Signature(inode: UInt64(st.st_ino), size: Int64(st.st_size), modified: st.st_mtimespec)
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }  // not there yet; the directory watch covers its arrival
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            // The vnode we hold no longer names the file: watch whatever does now.
            if events.contains(.delete) || events.contains(.rename) { self.armFile() }
            self.changed(fileEvent: true)
        }
        source.setCancelHandler { close(fd) }
        fileSource = source
        source.resume()
    }

    private func armDirectory() {
        let directory = url.deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRetry()
            return
        }
        retryTimer?.cancel()
        retryTimer = nil
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // The directory itself went away (cswap uninstalled): wait for
                // it to come back rather than watch a dead vnode.
                self.directorySource?.cancel()
                self.directorySource = nil
                self.fileSource?.cancel()
                self.fileSource = nil
                self.scheduleRetry()
                return
            }
            // A new file renamed into place is a different vnode from the one
            // the file source holds.
            if let now = self.currentSignature(), now.inode != self.signature?.inode {
                self.armFile()
            }
            self.changed()
        }
        source.setCancelHandler { close(fd) }
        directorySource = source
        source.resume()
    }

    private func scheduleRetry() {
        guard !cancelled, retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, !self.cancelled else { return }
            let directory = self.url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.armDirectory()
            self.armFile()
            self.changed()
        }
        retryTimer = timer
        timer.resume()
    }

    /// Trailing-edge debounce, then report only a real change.
    private func changed(fileEvent: Bool = false) {
        guard !cancelled else { return }
        if fileEvent { pendingFileEvent = true }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            self.pending = nil
            let now = self.currentSignature()
            let forced = self.reportsEveryEvent && self.pendingFileEvent
            self.pendingFileEvent = false
            guard forced || now != self.signature else { return }
            self.signature = now
            guard now != nil else { return }  // gone: nothing to read until it is back
            // Only a write moves this signature — a read changes no inode, size
            // or modification time — so the look below, which only reads,
            // cannot feed itself an event.
            self.handler()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
