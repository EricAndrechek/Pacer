import Foundation

/// Runs one shell command as root, behind macOS's own administrator-password
/// dialog, for the few things only root may do (#257: a link in
/// /usr/local/bin). Only ever on the user's click.
///
/// `osascript`'s `do shell script … with administrator privileges` is the
/// system's authorization prompt, not UI scripting: no Apple Event goes to any
/// other app, and nothing is clicked or typed for the user. A child process,
/// so the caller's thread is only blocked for as long as it chooses to wait;
/// call it off the main actor.
enum AdminShell {

    enum Outcome: Equatable, Sendable {
        case succeeded
        /// The user dismissed the password dialog. Not an error.
        case cancelled
        case failed(String)
    }

    static func run(_ script: String, prompt: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(literal(script)) with prompt \(literal(prompt)) "
                                   + "with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed("\(error)") }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return .succeeded }
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // -128 is AppleScript's "User canceled."
        if message.contains("-128") { return .cancelled }
        return .failed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
    }

    /// An AppleScript string literal: backslashes and double quotes escaped.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
