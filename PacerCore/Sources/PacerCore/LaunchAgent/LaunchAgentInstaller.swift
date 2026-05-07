import Foundation
import ServiceManagement

/// Wraps `SMAppService.agent` for the embedded `PacerDaemon` LaunchAgent
/// AND surfaces the runtime state of the dev-mode daemon registered via
/// `launchctl bootstrap` from `make install`. The two registration paths
/// are separate (SMAppService vs raw launchctl) and the user needs to
/// see both — otherwise the Debug tab claims "notFound" while a daemon
/// is plainly running and writing to the store.
///
/// **Pacer never auto-registers the SMAppService variant.** Per the
/// project's composable-integrations and pause-and-confirm guidance,
/// installing a LaunchAgent under SMAppService is a long-lived system
/// change the user must consent to. The dev variant runs under a
/// distinct label (`.dev`) and is set up by `make install` for
/// daily-driver iteration without going through System Settings.
public enum LaunchAgentInstaller {

    /// Filename of the LaunchAgent plist embedded in the app bundle.
    /// Must match what's actually copied into
    /// `Contents/Library/LaunchAgents/` by the build phase.
    public static let plistName = "com.ericandrechek.pacer.daemon.plist"

    /// Label of the dev-mode LaunchAgent installed by `bin/dev-install.sh`.
    /// Lives in `~/Library/LaunchAgents/` and is registered via
    /// `launchctl bootstrap` rather than SMAppService.
    public static let devLaunchctlLabel = "com.ericandrechek.pacer.daemon.dev"

    public enum Status: String, Sendable, CaseIterable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown
    }

    public enum DevDaemonState: Sendable, Equatable {
        /// Registered with launchd AND running. PID is exposed for the
        /// debug UI; nil means the label is loaded but `PID` was missing
        /// from `launchctl list` output.
        case running(pid: Int?)
        /// Label is bootstrapped (visible in `launchctl list`) but the
        /// process exited and hasn't been restarted yet (KeepAlive is
        /// throttled, the daemon crashed and is in the cooldown).
        case loadedNotRunning
        /// `launchctl list <label>` returned non-zero — label is not
        /// known to launchd. This is the typical state for a fresh
        /// checkout that hasn't run `make install`.
        case notLoaded
    }

    public struct CombinedStatus: Sendable {
        /// SMAppService-managed registration. The Register/Unregister
        /// buttons in the Debug tab toggle this.
        public let smAppService: Status
        /// launchctl-managed dev daemon (set up by `make install`).
        /// Read-only from inside the app — not toggle-able from the UI;
        /// the dev install script owns its lifecycle.
        public let devLaunchctl: DevDaemonState

        public init(smAppService: Status, devLaunchctl: DevDaemonState) {
            self.smAppService = smAppService
            self.devLaunchctl = devLaunchctl
        }
    }

    public static func currentStatus() -> Status {
        let agent = SMAppService.agent(plistName: plistName)
        return Self.map(agent.status)
    }

    /// Combined snapshot used by the Debug tab. Resolves both the
    /// SMAppService and dev-launchctl states so the UI can show "yes
    /// the daemon is running, even though SMAppService says notFound."
    public static func combinedStatus() -> CombinedStatus {
        CombinedStatus(
            smAppService: currentStatus(),
            devLaunchctl: queryDevLaunchctlState()
        )
    }

    public static func register() throws {
        let agent = SMAppService.agent(plistName: plistName)
        try agent.register()
    }

    public static func unregister() async throws {
        let agent = SMAppService.agent(plistName: plistName)
        try await agent.unregister()
    }

    /// macOS opens the user's "Login Items & Extensions" preferences
    /// pane to the section where the user can approve/deny the agent.
    /// Useful when `currentStatus()` returns `.requiresApproval` —
    /// without this, users have to navigate there manually.
    public static func openSystemSettingsApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> Status {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    /// Run `launchctl list <devLaunchctlLabel>` and parse the output to
    /// figure out whether the dev daemon is running. We avoid
    /// `launchctl print gui/<uid>/<label>` because it requires
    /// non-trivial parsing; `launchctl list` returns a small
    /// quoted-key plist-ish dictionary that's easy to grep.
    ///
    /// Exit code 0 with output → registered. Output contains a `PID`
    /// line iff the process is currently running. Anything else → not
    /// loaded.
    private static func queryDevLaunchctlState() -> DevDaemonState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", devLaunchctlLabel]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .notLoaded
        }
        guard process.terminationStatus == 0 else {
            return .notLoaded
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if let pid = parsePID(in: text) {
            return .running(pid: pid)
        }
        return .loadedNotRunning
    }

    /// Looks for `"PID" = 12345;` in `launchctl list` output. Returns
    /// nil when the line is absent (label registered but not running).
    private static func parsePID(in launchctlOutput: String) -> Int? {
        for line in launchctlOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"PID\"") else { continue }
            // Format: `"PID" = 12345;` — split on `=` and trim trailing `;`
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "; \t"))
            return Int(value)
        }
        return nil
    }
}
