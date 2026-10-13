import Foundation

/// Puts `pacer` on the PATH for an install that did not come from Homebrew
/// (#257), so `pacer report` works in any terminal.
///
/// Homebrew's cask links it into its own `bin`. A DMG install needs
/// `/usr/local/bin`, the one folder on macOS's default PATH a link can go in
/// (`~/.local/bin` is not on it). That folder is often the user's own already
/// (Homebrew on Intel, many developer tools), and then this needs no password
/// at all. Only when it is root-owned (a fresh Apple Silicon Mac) does it ask
/// for an administrator password, once, on the user's click. Either way it
/// links
///
///     /usr/local/bin/pacer → ~/Library/Application Support/Pacer/bin/pacer
///                          → <the running app>/Contents/Helpers/PacerCLI.app/Contents/MacOS/pacer
///
/// The middle link is the user's own file. Pacer re-points it at every launch,
/// so a moved or updated app never needs the password again; the root-owned
/// link never changes.
///
/// The rules match the skill installer's: install on a click, never replace a
/// `pacer` that is not ours, remove only what we put there, and step aside
/// when Homebrew already provides one.
public struct CommandLineToolInstaller: Sendable {

    public enum State: Equatable, Sendable {
        /// No command line in this build.
        case unavailable
        case notInstalled
        /// Our link is on the PATH.
        case installed
        /// A link into a Pacer.app that is not ours: Homebrew's cask.
        case homebrew(path: String)
        /// Something else named `pacer` is where ours would go.
        case foreign(path: String)
    }

    /// The executable inside the running app.
    public let cli: URL?
    /// The user-owned link Pacer keeps pointed at `cli`.
    public let userLink: URL
    /// The root-owned link on the PATH.
    public let systemLink: URL
    /// Where Homebrew's cask would put its link (Apple Silicon, then Intel).
    public let homebrewLinks: [URL]

    public static let systemLinkPath = "/usr/local/bin/pacer"

    public init(cli: URL?, userLink: URL,
                systemLink: URL = URL(fileURLWithPath: systemLinkPath),
                homebrewLinks: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin/pacer"),
                                        URL(fileURLWithPath: systemLinkPath)]) {
        self.cli = cli
        self.userLink = userLink
        self.systemLink = systemLink
        self.homebrewLinks = homebrewLinks
    }

    /// The installer for the running app.
    public static func bundled(_ bundle: Bundle = .main, home: URL? = nil) -> CommandLineToolInstaller {
        let cli = bundle.bundleURL.appendingPathComponent(ClaudeSkillInstaller.cliPathInApp)
        let root = home ?? FileManager.default.homeDirectoryForCurrentUser
        return CommandLineToolInstaller(
            cli: FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil,
            userLink: root.appendingPathComponent("Library/Application Support/Pacer/bin/pacer"))
    }

    // MARK: - State

    public func state() -> State {
        guard cli != nil else { return .unavailable }
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: systemLink.path) {
            if target == userLink.path { return .installed }
            if Self.isPacerCLI(systemLink) { return .homebrew(path: systemLink.path) }
            return .foreign(path: systemLink.path)
        }
        if fm.fileExists(atPath: systemLink.path) { return .foreign(path: systemLink.path) }
        for link in homebrewLinks where link.path != systemLink.path && Self.isPacerCLI(link) {
            return .homebrew(path: link.path)
        }
        return .notInstalled
    }

    /// Whether `url` resolves to a Pacer command line, wherever its app is.
    static func isPacerCLI(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return false }
        return url.resolvingSymlinksInPath().path.hasSuffix("/" + ClaudeSkillInstaller.cliPathInApp)
    }

    // MARK: - The user-owned link

    /// Point the user-owned link at the running app's command line. No
    /// password: the folder is the user's. Returns whether anything changed.
    @discardableResult
    public func refreshUserLink() throws -> Bool {
        guard let cli else { return false }
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: userLink.path)) == cli.path { return false }
        try fm.createDirectory(at: userLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: userLink.path)) != nil || fm.fileExists(atPath: userLink.path) {
            try fm.removeItem(at: userLink)
        }
        try fm.createSymbolicLink(at: userLink, withDestinationURL: cli)
        return true
    }

    /// At launch: keep an installed command line pointed at this app.
    @discardableResult
    public func refreshIfInstalled() throws -> Bool {
        guard state() == .installed else { return false }
        return try refreshUserLink()
    }

    /// After the root-owned link is gone, the user-owned one goes too.
    public func removeUserLink() {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: userLink.path)) != nil {
            try? FileManager.default.removeItem(at: userLink)
        }
    }

    // MARK: - The link on the PATH

    /// Whether installing (or removing) needs an administrator password:
    /// `/usr/local/bin` is not writable by this user, or does not exist and
    /// cannot be made. Settings says so before macOS asks.
    public var needsPrivileges: Bool {
        // The nearest folder that exists decides: the link's own, or the one
        // `createDirectory` would have to make it in.
        let fm = FileManager.default
        var dir = systemLink.deletingLastPathComponent()
        while dir.path != "/" {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                return !(isDir.boolValue && fm.isWritableFile(atPath: dir.path))
            }
            dir = dir.deletingLastPathComponent()
        }
        return true
    }

    /// Link without a password, when `needsPrivileges` is false. Like the
    /// script, it never replaces anything already there.
    public func installWithoutPrivileges() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: systemLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: systemLink, withDestinationURL: userLink)
    }

    /// Remove the link without a password, only if it is ours.
    public func uninstallWithoutPrivileges() throws {
        guard state() == .installed else { return }
        try FileManager.default.removeItem(at: systemLink)
    }

    // MARK: - The same, as shell for the privileged step

    /// Creates `/usr/local/bin` if needed and the link. `ln -s` without `-f`
    /// fails rather than replace anything that appeared since the check.
    public var installScript: String {
        "/bin/mkdir -p \(Self.quoted(systemLink.deletingLastPathComponent().path))"
            + " && /bin/ln -s \(Self.quoted(userLink.path)) \(Self.quoted(systemLink.path))"
    }

    /// Removes the link only if it is still ours.
    public var uninstallScript: String {
        "[ \"$(/usr/bin/readlink \(Self.quoted(systemLink.path)))\" = \(Self.quoted(userLink.path)) ]"
            + " && /bin/rm -f \(Self.quoted(systemLink.path))"
    }

    /// POSIX single-quoting: safe for any path, spaces and quotes included.
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
