import Foundation

/// The version Pacer shows for itself: a release's marketing version
/// ("0.9.4"), or for a build made from a checkout what git says it is:
/// "0.9.4+14 · dev (9eb8c89)", fourteen commits past v0.9.4, with a `*` after
/// the commit when the build had changes not yet committed.
///
/// Why not just `CFBundleShortVersionString`: a local build carries
/// project.yml's placeholder there (the release workflow stamps the real one
/// from the tag), so it would claim to be a release it is not. A local build
/// gets its git state in Info.plist instead (`PacerGitDescribe`,
/// `PacerGitSHA`, `PacerGitDirty`, from `bin/build-git-info.sh` through
/// `bin/dev-install.sh`, `make verify` and `make app`); a release build leaves
/// them empty and shows its version.
public struct AppVersionLabel: Sendable, Equatable {

    /// A local build, as far as git could say.
    public struct DevBuild: Sendable, Equatable {
        /// The last version tag at or before the commit, without its `v`.
        public var base: String?
        /// Commits since that tag.
        public var ahead: Int?
        /// Seven characters of the commit.
        public var commit: String?
        /// The bundle's code had uncommitted changes when it was built.
        public var dirty: Bool
        /// `git describe --tags --long`, as stamped: for reports.
        public var describe: String?

        public init(base: String? = nil, ahead: Int? = nil, commit: String? = nil, dirty: Bool = false,
                    describe: String? = nil) {
            self.base = base; self.ahead = ahead; self.commit = commit; self.dirty = dirty
            self.describe = describe
        }
    }

    public enum Kind: Sendable, Equatable {
        case release(String)
        case dev(DevBuild)
    }

    /// The Info.plist keys a local build fills (project.yml).
    public static let describeKey = "PacerGitDescribe"
    public static let shaKey = "PacerGitSHA"
    public static let dirtyKey = "PacerGitDirty"

    public let kind: Kind
    /// `CFBundleVersion`, a unix timestamp: for a tooltip, never the label.
    public let build: String?

    public init(kind: Kind, build: String? = nil) {
        self.kind = kind
        self.build = build
    }

    /// From an Info.plist dictionary. `isDebugBuild` covers a Debug build that
    /// recorded no git state (Xcode, a checkout without git): still not a
    /// release.
    public init(info: [String: Any], isDebugBuild: Bool) {
        let build = Self.value(info["CFBundleVersion"])
        let describe = Self.value(info[Self.describeKey])
        let parsed = describe.flatMap(Self.parseDescribe)
        let commit = Self.shortCommit(Self.value(info[Self.shaKey])) ?? parsed?.commit
        let dirty = ["1", "true", "yes", "dirty"].contains(Self.value(info[Self.dirtyKey])?.lowercased() ?? "")
        if describe != nil || commit != nil {
            self.init(kind: .dev(DevBuild(base: parsed?.base, ahead: parsed?.ahead, commit: commit,
                                          dirty: dirty, describe: describe)),
                      build: build)
        } else if isDebugBuild {
            self.init(kind: .dev(DevBuild()), build: build)
        } else {
            self.init(kind: .release(Self.value(info["CFBundleShortVersionString"]) ?? "0"), build: build)
        }
    }

    /// A non-empty string, or nil (an empty build setting, an unexpanded `$(…)`).
    private static func value(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.hasPrefix("$(") else { return nil }
        return text
    }

    /// `v0.9.4-14-g9eb8c89` → ("0.9.4", 14, "9eb8c89"). Anything else is nil.
    static func parseDescribe(_ describe: String) -> (base: String, ahead: Int, commit: String)? {
        // From the right: a tag may itself contain dashes ("v1.0.0-beta.2").
        let parts = describe.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let ahead = Int(parts[parts.count - 2]),
              parts[parts.count - 1].hasPrefix("g"),
              let commit = shortCommit(String(parts[parts.count - 1].dropFirst())) else { return nil }
        var tag = parts[..<(parts.count - 2)].joined(separator: "-")
        if tag.hasPrefix("v") { tag.removeFirst() }
        guard !tag.isEmpty else { return nil }
        return (tag, ahead, commit)
    }

    /// Seven hex characters of a commit. Anything that is not a hex commit is
    /// no commit.
    static func shortCommit(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.count >= 7, raw.allSatisfy(\.isHexDigit) else { return nil }
        return String(raw.prefix(7))
    }

    public var isRelease: Bool {
        if case .release = kind { return true }
        return false
    }

    /// "0.9.4"; "0.9.4+14 · dev (9eb8c89)", "0.9.4 · dev (9eb8c89*)" on the
    /// tag itself with uncommitted changes, "dev (9eb8c89)" with no tag in
    /// reach, or "dev".
    public var text: String {
        switch kind {
        case .release(let version):
            return version
        case .dev(let dev):
            var version: String?
            if let base = dev.base {
                if let ahead = dev.ahead, ahead > 0 { version = "\(base)+\(ahead)" } else { version = base }
            }
            var tail = "dev"
            if let commit = dev.commit { tail += " (\(commit)\(dev.dirty ? "*" : ""))" }
            return [version, tail].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The sidebar footer's and the status menu's line: "Pacer 0.9.4".
    public var title: String { "Pacer \(text)" }

    /// The same label from longest to shortest, for a line that shows the
    /// most that fits rather than cutting one off mid-commit: "Pacer 0.9.4+14
    /// · dev (9eb8c89)", "0.9.4+14 · dev (9eb8c89)", "0.9.4+14 · dev", "dev".
    /// A release has two: "Pacer 0.9.4", "0.9.4".
    public var fittedTitles: [String] {
        var forms = [title, text]
        if case .dev(let dev) = kind {
            if let base = dev.base {
                let version = (dev.ahead ?? 0) > 0 ? "\(base)+\(dev.ahead ?? 0)" : base
                forms.append("\(version) · dev")
            }
            forms.append("dev")
        }
        var seen = Set<String>()
        return forms.filter { seen.insert($0).inserted }
    }

    /// The About window's line: "Version 0.9.4".
    public var aboutLine: String { "Version \(text)" }

    /// "Build 1780503333", for a tooltip; nil when the bundle has none.
    public var buildLine: String? { build.map { "Build \($0)" } }

    /// The version a report names, X.Y.Z as the feedback endpoint requires: a
    /// release's, or a dev build's last tag ("0.0.0" with none in reach).
    /// Never the display label, which has spaces.
    public var reportVersion: String {
        switch kind {
        case .release(let version): return version
        case .dev(let dev): return dev.base ?? "0.0.0"
        }
    }

    /// A dev build's `git describe`, `-dirty` appended as git's own `--dirty`
    /// would: for reports. Nil for a release.
    public var reportDescribe: String? {
        guard case .dev(let dev) = kind else { return nil }
        let core = dev.describe ?? dev.commit
        return core.map { dev.dirty ? "\($0)-dirty" : $0 }
    }
}

/// Where Pacer's own update stands, for the surfaces that show it (the
/// sidebar footer, the status menu, the app menu).
///
/// `readyToInstall` is never reached through `applying(_:)`: an update is
/// ready exactly while `UpdateInstallScheduler` holds Sparkle's install
/// block, so the app derives it from that hold (`resolve`). Two records of
/// "ready" could disagree; one cannot.
public enum UpdateState: Sendable, Equatable {
    /// Nothing to act on: no check running, nothing downloaded. Also the
    /// state before the first check, so the surfaces never claim more.
    case upToDate
    case checking
    case downloading(version: String)
    case readyToInstall(version: String)
    /// The install was started (a click or the policy) and Pacer has not
    /// relaunched yet: the action is shown, disabled.
    case installing(version: String)
    case failed

    /// What Sparkle reported, in the order its delegate reports it.
    public enum Event: Sendable, Equatable {
        /// `mayPerform` let a check through.
        case checkStarted
        case noUpdate
        case downloadStarted(version: String)
        case downloadFailed
        /// Downloaded and extracted: from here Sparkle's own prompt or the
        /// install hold has it, and the hold is what `resolve` reads.
        case prepared
        /// `didAbortWithError`; `noUpdate` for Sparkle's "you're up to date",
        /// which arrives through the error channel.
        case aborted(noUpdate: Bool)
        /// `didFinishUpdateCycle`; `failed` for any error but "no update".
        /// The backstop: nothing in progress outlives its cycle.
        case cycleFinished(failed: Bool)
    }

    public func applying(_ event: Event) -> UpdateState {
        switch event {
        case .checkStarted: return .checking
        case .noUpdate, .prepared: return .upToDate
        case .downloadStarted(let version): return .downloading(version: version)
        case .downloadFailed: return .failed
        case .aborted(let noUpdate): return noUpdate ? .upToDate : .failed
        case .cycleFinished(let failed):
            // A failure reported earlier in the cycle stands; the cycle's own
            // end does not always repeat the error.
            if failed || self == .failed { return .failed }
            return .upToDate
        }
    }

    /// The state to show: a held update wins over whatever the last check
    /// said, since nothing else can run while it is held.
    public static func resolve(phase: UpdateState, heldVersion: String?, installing: Bool = false) -> UpdateState {
        if let heldVersion {
            return installing ? .installing(version: heldVersion) : .readyToInstall(version: heldVersion)
        }
        switch phase {
        case .readyToInstall, .installing: return .upToDate
        default: return phase
        }
    }

    /// Sparkle's "you're up to date" (`SUNoUpdateError`).
    public static func isNoUpdate(domain: String, code: Int) -> Bool {
        domain == UpdateOutcomeLog.sparkleErrorDomain && code == UpdateOutcomeLog.sparkleNoUpdateCode
    }

    /// The held update's version, ready or already installing.
    public var readyVersion: String? {
        switch self {
        case .readyToInstall(let version), .installing(let version): return version
        default: return nil
        }
    }

    public var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }

    /// A render override (`PACER_RENDER_UPDATE_STATE`): `up-to-date`,
    /// `checking`, `downloading:0.9.5`, `ready:0.9.5`, `failed`.
    public init?(override raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1).map(String.init)
        guard let name = parts.first?.lowercased() else { return nil }
        let version = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        switch name {
        case "up-to-date", "uptodate", "idle": self = .upToDate
        case "checking": self = .checking
        case "failed": self = .failed
        case "downloading":
            guard let version else { return nil }
            self = .downloading(version: version)
        case "ready", "readytoinstall":
            guard let version else { return nil }
            self = .readyToInstall(version: version)
        case "installing":
            guard let version else { return nil }
            self = .installing(version: version)
        default: return nil
        }
    }

    /// For a render's file name: `up-to-date`, `downloading-0.9.5`, ….
    public var token: String {
        switch self {
        case .upToDate: return "up-to-date"
        case .checking: return "checking"
        case .downloading(let version): return "downloading-\(version)"
        case .readyToInstall(let version): return "ready-\(version)"
        case .installing(let version): return "installing-\(version)"
        case .failed: return "failed"
        }
    }
}

/// The update strings, one place for every surface.
public enum UpdateCopy {
    public static let checkForUpdates = "Check for Updates…"

    /// The sidebar footer's update row, while one is ready: what the click
    /// does, and under it what is waiting.
    public static let sidebarInstall = "Restart to Update"
    public static func sidebarReady(_ version: String) -> String { "Pacer \(version) is ready" }
    /// The same row once the install has started.
    public static let sidebarInstalling = "Restarting…"

    /// The status menu's and the app menu's item.
    public static func menuInstall(_ version: String) -> String { "Update to \(version) — Restart" }

    public static func downloading(_ version: String) -> String { "Downloading \(version)…" }

    /// The status menu's update item: only while an update is ready (shown
    /// disabled once it is installing, `UpdateState.isInstalling`).
    public static func menuInstallTitle(for state: UpdateState) -> String? {
        state.readyVersion.map(menuInstall)
    }
}
