import Foundation

/// A throwaway `UserDefaults` suite that removes itself, plist file included (#464).
///
/// `removePersistentDomain(forName:)` empties a suite but leaves
/// `~/Library/Preferences/<suite>.plist` behind, and a test process is not
/// sandboxed, so every `UserDefaults(suiteName:)` a test made stayed on the
/// machine for good (29k files on one Mac). Tests never call
/// `UserDefaults(suiteName:)` themselves (`TestDefaultsLintTests` fails if they
/// do); they hold a `TestDefaults`, or ask `scratch` for a bare store.
final class TestDefaults: @unchecked Sendable {
    let suiteName: String
    let defaults: UserDefaults

    init(prefix: String = "default") {
        suiteName = "pacer.tests.\(prefix).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit { cleanup() }

    /// Idempotent. Empties the suite and deletes its plist now, and hands the
    /// path to `Reaper` for the delete that sticks (see there).
    func cleanup() { Self.cleanup(suite: suiteName) }

    static func cleanup(suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist").path
        try? FileManager.default.removeItem(atPath: path)
        Reaper.shared.add(path)
    }
}

/// Deletes the plists once cfprefsd has stopped writing them (#464).
///
/// Removing a suite, synchronizing and deleting the file is not enough:
/// cfprefsd flushes the removal on its own timer, 2 to 3 seconds later, and
/// writes the file back (an empty one). Measured: gone at +2 s, back at +3 s,
/// with the process still alive. And the process may end before the flush.
/// So the paths go to one detached shell per test process, which waits for
/// the process to end, waits out the flush, and deletes them.
private final class Reaper: @unchecked Sendable {
    static let shared = Reaper()

    private let lock = NSLock()
    private var list: FileHandle?

    func add(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        if list == nil { list = start() }
        try? list?.write(contentsOf: Data((path + "\n").utf8))
    }

    private func start() -> FileHandle? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-test-defaults-\(getpid()).list")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return nil }
        let reaper = Process()
        reaper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `kill -0` on the test process: it is our parent, so this holds until it ends.
        reaper.arguments = ["-c", """
            while kill -0 "$1" 2>/dev/null; do sleep 1; done
            sleep 8
            while IFS= read -r p; do rm -f "$p"; done < "$2"
            rm -f "$2"
            """, "sh", String(getpid()), file.path]
        reaper.standardInput = FileHandle.nullDevice
        reaper.standardOutput = FileHandle.nullDevice
        reaper.standardError = FileHandle.nullDevice
        do { try reaper.run() } catch { return nil }
        return handle
    }
}

/// For a suite struct whose helpers hand out bare `UserDefaults`: keep one as a
/// stored property (`private let defaultsBag = TestDefaultsBag()`). Swift Testing
/// makes a fresh suite instance per test and frees it afterwards, and that
/// `deinit` cleans every suite handed out. (A `UserDefaults` subclass that
/// cleans on its own `deinit` does not work: cfprefsd observers keep it alive.)
final class TestDefaultsBag: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [TestDefaults] = []

    func make(prefix: String = "bag") -> UserDefaults {
        let t = TestDefaults(prefix: prefix)
        lock.lock(); held.append(t); lock.unlock()
        return t.defaults
    }

    deinit { for t in held { t.cleanup() } }
}

/// Runs `body` with a fresh suite and cleans it up afterwards.
func withTestDefaults<T>(prefix: String = "default", _ body: (UserDefaults) throws -> T) rethrows -> T {
    let t = TestDefaults(prefix: prefix)
    defer { t.cleanup() }
    return try body(t.defaults)
}

func withTestDefaults<T>(prefix: String = "default", _ body: (UserDefaults) async throws -> T) async rethrows -> T {
    let t = TestDefaults(prefix: prefix)
    defer { t.cleanup() }
    return try await body(t.defaults)
}
