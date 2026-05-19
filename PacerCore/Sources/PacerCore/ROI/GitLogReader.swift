import Foundation

/// Reads `git log` from a project directory and parses the output into
/// structured `GitCommit` values. Pacer doesn't depend on libgit2 or
/// any Swift git binding — `/usr/bin/git` is available on every macOS
/// and parsing its `--numstat --pretty` output is cheap.
///
/// The runner is injectable so tests can pass canned output without
/// shelling out. Production code uses `systemRunner`, which actually
/// invokes git.
public enum GitLogReader {

    /// One commit reachable from HEAD in the given window. Lines
    /// added/removed are summed across every file the commit touched
    /// (excluding binary files, which git reports as `-` and we
    /// silently treat as zero).
    public struct Commit: Sendable, Equatable {
        public let hash: String
        public let date: Date
        public let linesAdded: Int
        public let linesRemoved: Int

        public init(hash: String, date: Date, linesAdded: Int, linesRemoved: Int) {
            self.hash = hash
            self.date = date
            self.linesAdded = linesAdded
            self.linesRemoved = linesRemoved
        }

        public var totalLinesChanged: Int { linesAdded + linesRemoved }
    }

    /// Closure shape for invoking git. Tests pass a pure function
    /// returning canned stdout; production passes `systemRunner`,
    /// which actually spawns `/usr/bin/git`.
    public typealias Runner = @Sendable (URL, [String]) async throws -> String

    /// Errors specific to this reader. Subprocess crashes/timeouts
    /// surface as `runFailure`; downstream callers swallow these into
    /// "skip this repo" rather than failing the whole ROI compute.
    public enum ReaderError: Error, Sendable {
        case runFailure(String)
    }

    /// Production runner — shells out to `/usr/bin/git`. Sandboxed
    /// callers will fail here; Pacer isn't sandboxed, so the spawn
    /// always works given an existing repo root.
    public static let systemRunner: Runner = { repoRoot, args in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repoRoot

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                // Drain stdout before resuming — readDataToEndOfFile
                // blocks until EOF which is fine post-termination.
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    let s = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: s)
                } else {
                    let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: err, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ReaderError.runFailure(
                        "git \(args.joined(separator: " ")) failed (\(proc.terminationStatus)): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Read commits authored since `since` from `repoRoot`. Returns an
    /// empty array if the repo has no commits in the window, or if
    /// `repoRoot` isn't a git repo at all (the runner surfaces a
    /// `runFailure` and we treat it as "no data").
    ///
    /// `--no-merges` excludes merge commits so cost/commit isn't
    /// diluted by automation. `--numstat` produces the
    /// added/removed/file rows we parse.
    public static func commits(
        in repoRoot: URL,
        since: Date,
        runner: Runner = systemRunner
    ) async -> [Commit] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let sinceStr = f.string(from: since)
        let args = [
            "log",
            "--since=\(sinceStr)",
            "--numstat",
            "--pretty=format:COMMIT %H %aI",
            "--no-merges"
        ]
        do {
            let output = try await runner(repoRoot, args)
            return parse(output: output)
        } catch {
            return []
        }
    }

    /// Parse `git log --numstat --pretty=format:"COMMIT %H %aI"` output:
    ///
    ///     COMMIT abc123 2026-05-19T10:30:00-07:00
    ///     5    2    file1.swift
    ///     3    0    file2.swift
    ///
    ///     COMMIT def456 2026-05-18T11:00:00-07:00
    ///     10    5    file3.swift
    ///
    /// Lines starting with "COMMIT " open a new commit; tab-separated
    /// `<added>\t<removed>\t<file>` lines add to the running totals;
    /// blank lines separate commits. Binary files show `-` for the
    /// counts — we treat that as zero. Final newline omitted by
    /// `--pretty=format:` (vs `tformat:`) so the parser flushes the
    /// in-progress commit when the input ends.
    static func parse(output: String) -> [Commit] {
        var commits: [Commit] = []
        var pendingHash: String?
        var pendingDate: Date?
        var added = 0
        var removed = 0

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        func flush() {
            if let h = pendingHash, let d = pendingDate {
                commits.append(Commit(
                    hash: h, date: d,
                    linesAdded: added, linesRemoved: removed
                ))
            }
            pendingHash = nil
            pendingDate = nil
            added = 0
            removed = 0
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("COMMIT ") {
                flush()
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count >= 3 else { continue }
                pendingHash = String(parts[1])
                pendingDate = iso.date(from: String(parts[2]))
                continue
            }
            if line.isEmpty { continue }
            // Numstat row: "<added>\t<removed>\t<file>"
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3 else { continue }
            let a = Int(cols[0]) ?? 0
            let r = Int(cols[1]) ?? 0
            added += a
            removed += r
        }
        flush()
        return commits
    }
}
