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

    /// An absolute path (no `.plist`): `UserDefaults(suiteName:)` then keeps the
    /// plist at that path, so nothing lands in ~/Library/Preferences at all.
    /// (A named suite there is re-written by cfprefsd 2-3 s after any removal,
    /// even after the process has exited, so it cannot be cleaned up.)
    static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-test-defaults-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(prefix: String = "default") {
        suiteName = Self.directory.appendingPathComponent("\(prefix).\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit { cleanup() }

    /// Idempotent.
    func cleanup() { Self.cleanup(suite: suiteName) }

    static func cleanup(suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
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
