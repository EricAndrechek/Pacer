import Foundation

/// Shared wrapper around `/usr/bin/security find-generic-password -w`.
///
/// Both `KeychainOAuth` (Claude Code's plaintext credential) and
/// `DesktopOAuth` (Claude Desktop's safeStorage AES key) read keychain
/// items through the Apple-signed `security` CLI rather than
/// `SecItemCopyMatching` — see the `KeychainOAuth` type doc for the
/// partition-list rationale (the CLI avoids the recurring prompt that a
/// direct SecItem read from Pacer's Team ID would trigger).
///
/// Note: for items created by a third app with a restrictive ACL (e.g.
/// Claude Desktop's `Claude Safe Storage`), the *first* read still pops a
/// one-time keychain approval; "Always Allow" then makes it silent. The
/// Claude Code item is the exception — Claude Code puts it in the
/// `apple-tool:` partition the CLI already belongs to, so it never prompts.
enum SecurityCLI {

    /// Neutral outcome; each caller maps these onto its own domain error.
    enum Failure: Error, Equatable {
        /// Exit 44 — `errSecItemNotFound` (item absent).
        case notFound
        /// Exit 36/51/128 — user declined, non-UI context, or the 5s
        /// modal-prompt safety timeout fired.
        case accessDenied
        /// Couldn't launch the subprocess (bad PATH, sandbox refusal).
        case spawn(OSStatus)
        /// Any other non-zero exit status.
        case status(OSStatus)
    }

    /// Convenience for the one call shape we use everywhere.
    static func findGenericPassword(service: String, account: String? = nil) -> Result<Data, Failure> {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        return run(args)
    }

    /// The binary every keychain read shells out to.
    static let securityExecutable = URL(fileURLWithPath: "/usr/bin/security")

    /// One-shot invocation with a 5-second timeout — a safety net for the
    /// pathological "locked keychain prompts modally" case so a bad
    /// keychain state can't wedge a caller (e.g. the poller actor) forever.
    ///
    /// **Both pipes are read while the process runs.** They used to be
    /// drained only after it exited, and a pipe holds 64 KB: an item, or a
    /// `security` diagnostic, bigger than that filled it, `security` blocked
    /// in `write(2)` waiting for a reader that was itself waiting for the
    /// exit, and the call sat out the whole timeout and came back as
    /// `.accessDenied`, a read that never prompted reported as a refusal.
    /// `PipeDrain` reads each to end-of-file on its own thread from launch.
    ///
    /// The timeout covers the exit *and* both reads: a descendant still
    /// holding a pipe open after the child exits cannot hold the caller
    /// past it either. On a timeout the child gets `terminate()` (SIGTERM).
    /// The app installs a no-op SIGTERM handler for its own shutdown, but a
    /// caught signal's handler is reset to the default across `exec`, so the
    /// child still dies of it.
    ///
    /// `executable` and `timeout` are test seams: a fake that writes past
    /// the pipe's capacity, or never exits (`SecurityCLITests`).
    static func run(
        _ args: [String],
        executable: URL = securityExecutable,
        timeout: TimeInterval = 5
    ) -> Result<Data, Failure> {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Set before `run()`, so an exit that comes first is not missed.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return .failure(.spawn(OSStatus((error as NSError).code)))
        }
        let deadline = DispatchTime.now() + timeout
        // `Process` closes the parent's copies of the write ends at launch,
        // so each read ends when the child (and anything it handed the pipe
        // to) does.
        let output = PipeDrain(stdout.fileHandleForReading)
        let errors = PipeDrain(stderr.fileHandleForReading)

        guard exited.wait(timeout: deadline) == .success,
              let data = output.wait(until: deadline),
              errors.wait(until: deadline) != nil
        else {
            if process.isRunning { process.terminate() }
            // The drains finish on their own threads once the pipes close;
            // nothing waits for them past this point.
            return .failure(.accessDenied)
        }

        switch process.terminationStatus {
        case 0:
            return .success(data)
        case 44:
            return .failure(.notFound)
        case 36, 51, 128:
            return .failure(.accessDenied)
        case let status:
            return .failure(.status(OSStatus(status)))
        }
    }
}

/// Reads one pipe to end-of-file on a background thread, from the moment it
/// is made, so the child never blocks on a full pipe. `wait(until:)` hands
/// over what was read, once; it returns nil if end-of-file has not come by
/// the deadline, and the read then finishes, unobserved, when the pipe
/// closes.
final class PipeDrain: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    /// Written once on the reader thread before `done` is signalled; read
    /// only after a successful wait on it, which orders the two.
    private var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = (try? handle.readToEnd()) ?? Data()
            done.signal()
        }
    }

    /// Everything the pipe carried, or nil if it is still open at
    /// `deadline`. Call at most once.
    func wait(until deadline: DispatchTime) -> Data? {
        done.wait(timeout: deadline) == .success ? data : nil
    }
}
