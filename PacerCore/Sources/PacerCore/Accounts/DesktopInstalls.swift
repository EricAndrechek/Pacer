import Darwin
import Foundation

/// One Claude Desktop data folder (#295).
///
/// People run several Desktops at once, usually one per account. Every
/// community tool for it launches the same Electron app with its own Chromium
/// profile (`open -n -a Claude --args --user-data-dir=<dir>`), so each install
/// is its data folder: its own `claude-code-sessions` and
/// `local-agent-mode-sessions` trees, and its own `config.json` token cache.
///
/// **Every install is equal.** The one at the standard location is not a main
/// install, only the one found without being told where to look. The folder is
/// also the only stable identity an install has: one install can hold logins
/// for more than one account, so the account cannot name it.
public struct DesktopInstall: Sendable, Hashable, Identifiable {
    /// The data folder, in `canonicalPathURL` form.
    public let dataDirectory: URL
    /// The `CLAUDE_CONFIG_DIR` this install's Claude Code writes to, when it
    /// has its own and Pacer has seen it. nil means `~/.claude`, the CLI's.
    public let configDirectory: URL?

    public init(dataDirectory: URL, configDirectory: URL? = nil) {
        self.dataDirectory = dataDirectory.canonicalPathURL
        self.configDirectory = configDirectory?.canonicalPathURL
    }

    public var id: String { dataDirectory.path }
    public var folderName: String { dataDirectory.lastPathComponent }
    /// Where the install keeps its encrypted token cache.
    public var tokenCacheFile: URL { dataDirectory.appendingPathComponent("config.json") }

    /// The name an install goes by: "Desktop" while it is the only one, else
    /// "Desktop · <folder>" with a leading "Claude" taken off the folder name
    /// ("Claude-Work" → "Desktop · Work"). The standard install's folder is
    /// just "Claude", which keeps its name rather than becoming empty.
    public static func labels(for installs: [DesktopInstall]) -> [String: String] {
        guard installs.count > 1 else {
            return Dictionary(uniqueKeysWithValues: installs.map { ($0.id, "Desktop") })
        }
        func name(_ install: DesktopInstall, parent: Bool) -> String {
            var base = install.folderName
            if base.lowercased().hasPrefix("claude") {
                let rest = base.dropFirst("claude".count)
                    .drop { " -_.".contains($0) }
                if !rest.isEmpty { base = String(rest) }
            }
            guard parent else { return base }
            return "\(install.dataDirectory.deletingLastPathComponent().lastPathComponent)/\(base)"
        }
        let short = installs.map { name($0, parent: false) }
        var out: [String: String] = [:]
        for (i, install) in installs.enumerated() {
            let clashes = short.filter { $0 == short[i] }.count > 1
            out[install.id] = "Desktop · \(name(install, parent: clashes))"
        }
        return out
    }
}

/// Where Claude Desktop installs are found (#295). Three places, and never a
/// search of the home folder:
///
/// 1. **The usual app-data location**: `~/Library/Application Support/Claude*`
///    folders that hold session records or a token cache. A folder with
///    neither is some other Anthropic app's (`Claude-3p` holds one config
///    file), and says nothing.
/// 2. **Running Desktops**: the `--user-data-dir` of each running Claude main
///    process, read from its arguments, plus the `CLAUDE_CONFIG_DIR` in its
///    environment when the system lets Pacer see it. Read-only; nothing else
///    from the environment is kept. Each one seen is remembered, so an install
///    that is not running is still counted.
/// 3. **Folders the user added** in Settings.
public enum DesktopInstallDiscovery {

    /// One running Desktop main process, as far as its launch says.
    public struct RunningDesktop: Sendable, Hashable {
        public let dataDirectory: URL?
        public let configDirectory: URL?
        public init(dataDirectory: URL?, configDirectory: URL?) {
            self.dataDirectory = dataDirectory
            self.configDirectory = configDirectory
        }
    }

    /// The installs, from what the three sources say. Pure, for tests:
    /// `remembered` is `[data folder: config folder or ""]`.
    public static func installs(
        applicationSupport: URL?,
        running: [RunningDesktop],
        remembered: [String: String],
        extraPaths: [String],
        fileManager fm: FileManager = .default
    ) -> [DesktopInstall] {
        var configByData: [String: URL?] = [:]
        var order: [String] = []
        func add(_ data: URL, config: URL?) {
            let key = data.canonicalPathURL.path
            guard isDirectory(data, fm) else { return }
            if configByData[key] == nil { order.append(key); configByData[key] = .some(nil) }
            if let config { configByData[key] = .some(config) }
        }
        if let applicationSupport {
            let entries = (try? fm.contentsOfDirectory(
                at: applicationSupport, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.lastPathComponent.hasPrefix("Claude") && looksLikeInstall(entry, fm) {
                add(entry, config: nil)
            }
        }
        // The default location is covered above; a running Desktop without
        // the argument adds nothing but may still name a config folder.
        let standard = applicationSupport?.appendingPathComponent("Claude")
        for desktop in running {
            guard let data = desktop.dataDirectory ?? standard else { continue }
            add(data, config: desktop.configDirectory)
        }
        for (data, config) in remembered.sorted(by: { $0.key < $1.key }) {
            add(URL(fileURLWithPath: data), config: config.isEmpty ? nil : URL(fileURLWithPath: config))
        }
        for path in extraPaths {
            add(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), config: nil)
        }
        return order.map { DesktopInstall(dataDirectory: URL(fileURLWithPath: $0),
                                          configDirectory: configByData[$0] ?? nil) }
    }

    /// Whether a folder holds anything only a Desktop install writes.
    static func looksLikeInstall(_ folder: URL, _ fm: FileManager) -> Bool {
        if isDirectory(folder.appendingPathComponent(DesktopSessionDirectory.codeSessionsFolder), fm)
            || isDirectory(folder.appendingPathComponent(DesktopSessionDirectory.agentSessionsFolder), fm) {
            return true
        }
        return DesktopOAuth.cacheBlobs(in: folder.appendingPathComponent("config.json"))?.isEmpty == false
    }

    private static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - This machine

    /// The installs on this machine now. Nothing in a test process, which
    /// must never read the developer's own Desktop. Remembers every install
    /// seen running, and forgets remembered folders that are gone.
    public static func current(store: UserDefaults = PacerPreferences.store) -> [DesktopInstall] {
        guard !PacerPreferences.isTestProcess else { return [] }
        let running = runningDesktops()
        var remembered = (store.dictionary(forKey: PacerPreferenceKeys.desktopRememberedInstalls)
            as? [String: String]) ?? [:]
        let before = remembered
        for desktop in running {
            guard let data = desktop.dataDirectory?.canonicalPathURL.path else { continue }
            let config = desktop.configDirectory?.canonicalPathURL.path
            remembered[data] = config ?? remembered[data] ?? ""
        }
        remembered = remembered.filter { FileManager.default.fileExists(atPath: $0.key) }
        if remembered != before {
            store.set(remembered, forKey: PacerPreferenceKeys.desktopRememberedInstalls)
        }
        return installs(
            applicationSupport: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support"),
            running: running, remembered: remembered,
            extraPaths: PacerPreferences.desktopExtraDataDirectories(from: store))
    }

    /// Every running Claude Desktop main process: the app's own executable,
    /// `<something>.app/Contents/MacOS/Claude`. Its helpers live elsewhere in
    /// the bundle, and the Claude Code CLI is `claude`, lowercase.
    ///
    /// Arguments and environment come from `KERN_PROCARGS2`, the same read
    /// `ps` makes, for processes of this user only. Only `--user-data-dir`
    /// and `CLAUDE_CONFIG_DIR` are looked at; the rest is never kept.
    public static func runningDesktops() -> [RunningDesktop] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        let uid = getuid()
        var out: [RunningDesktop] = []
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = String(cString: pathBuffer)
            guard path.hasSuffix(".app/Contents/MacOS/Claude") else { continue }
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                    Int32(MemoryLayout<proc_bsdinfo>.size))
            guard size > 0, info.pbi_uid == uid else { continue }
            guard let launch = launchStrings(pid: pid) else { continue }
            out.append(parse(arguments: launch.arguments, environment: launch.environment))
        }
        return out
    }

    /// The data and config folders a launch names. Pure, for tests.
    static func parse(arguments: [String], environment: [String]) -> RunningDesktop {
        var data: URL?
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg.hasPrefix("--user-data-dir=") {
                data = URL(fileURLWithPath: String(arg.dropFirst("--user-data-dir=".count)))
            } else if arg == "--user-data-dir", i + 1 < arguments.count {
                data = URL(fileURLWithPath: arguments[i + 1])
                i += 1
            }
            i += 1
        }
        let config = environment.first { $0.hasPrefix("CLAUDE_CONFIG_DIR=") }
            .map { String($0.dropFirst("CLAUDE_CONFIG_DIR=".count)) }
            .flatMap { raw in
                raw.split(separator: ",").first.map {
                    URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces))
                }
            }
        return RunningDesktop(dataDirectory: data, configDirectory: config)
    }

    /// `argv[1...]` and the environment of a process, or nil when the system
    /// will not say. The layout is `argc`, the executable path, padding, then
    /// `argc` NUL-terminated arguments, then the environment until an empty
    /// string.
    private static func launchStrings(pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The executable path, then NUL padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        var start = index
        while index < size {
            if buffer[index] == 0 {
                if index == start { break }   // an empty string ends the environment
                strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        let count = max(0, Int(argc))
        let arguments = Array(strings.prefix(count).dropFirst())
        let environment = Array(strings.dropFirst(count))
        return (arguments, environment)
    }
}
