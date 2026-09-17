import Foundation

extension URL {
    /// This URL in the one form Pacer compares and de-duplicates directory
    /// paths in: standardized, and explicitly not directory-style.
    ///
    /// `URL` equality compares `absoluteString`, which carries the trailing
    /// slash that marks a directory URL — and nothing makes two URLs for the
    /// same directory agree about that slash. `appendingPathComponent(_:)`
    /// never adds one, `URL(fileURLWithPath:)` asks the filesystem, and
    /// `FileManager`'s enumeration APIs changed their answer between OS
    /// releases: `contentsOfDirectory(at:)` returned `file:///…/1-work` on
    /// macOS 15 and returns `file:///…/1-work/` on macOS 26+. Identical
    /// `path`, unequal `URL`.
    ///
    /// That is not cosmetic. It silently defeated the overlap guard in
    /// `ScanCoordinator.resolveAllRoots()`, which drops a discovered session
    /// profile that is already a primary root by comparing `ResolvedRoot`
    /// values — synthesized `Equatable` over two `URL`s. On macOS 26+ the
    /// discovered copy carried a slash the constructed primary lacked, the
    /// guard stopped matching, and the same root would be scanned twice.
    ///
    /// Going through `.path` drops the slash; rebuilding with an explicit
    /// `isDirectory: false` keeps it off, deterministically and without
    /// touching the filesystem. The slash-less form is the deliberate choice:
    /// it is what every hand-built URL in this codebase already looks like
    /// and what macOS 15 produced, so one rule holds on every OS Pacer
    /// supports rather than a new rule starting at macOS 26. `FileManager`
    /// is indifferent — it works off `path`.
    ///
    /// Apply this wherever a path that came out of directory enumeration can
    /// meet one that was built by hand.
    var canonicalPathURL: URL {
        URL(fileURLWithPath: standardizedFileURL.path, isDirectory: false)
    }
}
