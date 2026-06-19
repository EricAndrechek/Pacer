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

    /// One-shot invocation with a 5-second timeout — a safety net for the
    /// pathological "locked keychain prompts modally" case so a bad
    /// keychain state can't wedge a caller (e.g. the poller actor) forever.
    static func run(_ args: [String]) -> Result<Data, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(.spawn(OSStatus((error as NSError).code)))
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            // Drain so the kernel doesn't hold the pipes open.
            _ = try? stdout.fileHandleForReading.readToEnd()
            _ = try? stderr.fileHandleForReading.readToEnd()
            return .failure(.accessDenied)
        }

        switch process.terminationStatus {
        case 0:
            return .success((try? stdout.fileHandleForReading.readToEnd()) ?? Data())
        case 44:
            return .failure(.notFound)
        case 36, 51, 128:
            return .failure(.accessDenied)
        case let status:
            return .failure(.status(OSStatus(status)))
        }
    }
}
