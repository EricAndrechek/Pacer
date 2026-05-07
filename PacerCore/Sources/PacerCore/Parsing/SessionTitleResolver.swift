import Foundation

/// Best-effort session-title lookup. Claude Code currently doesn't
/// emit an explicit `summary` line per session in the user's install,
/// so the natural "name" of a session is its first real user prompt
/// — what the user actually typed to start the conversation. This
/// actor walks the session's JSONL file, returns the first
/// non-`<local-command-…>` user message content (truncated), and
/// caches the result so we never re-read the same file twice.
///
/// Cheap: reads the file with a `LineByLineReader` shape and stops as
/// soon as it finds a hit (usually within the first ~50 lines).
public actor SessionTitleResolver {

    public static let shared = SessionTitleResolver()

    private var cache: [String: String?] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns a short, single-line title for the session, or nil if
    /// nothing usable is found. The first call resolves; subsequent
    /// calls hit the cache. Cache keyed on `sessionId` only — JSONLs
    /// for a session don't move in practice, so we don't bother
    /// invalidating on path changes.
    public func title(for sessionId: String) -> String? {
        if let cached = cache[sessionId] {
            return cached
        }
        let resolved = resolveFromDisk(sessionId: sessionId)
        cache[sessionId] = resolved
        return resolved
    }

    /// Drop the cache. Used by the eventual "rescan" admin button if
    /// we add one — not currently called.
    public func reset() {
        cache.removeAll()
    }

    // MARK: - Private

    private func resolveFromDisk(sessionId: String) -> String? {
        // The JSONL's filename is `<sessionId>.jsonl` under ANY of
        // the encoded-cwd directories under ~/.claude/projects. We
        // search them all because a worktree-spawned subagent's
        // session lives under a different directory than its parent
        // project's projectPath.
        let projectsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if fileManager.fileExists(atPath: candidate.path),
               let title = readFirstUserPromptText(at: candidate) {
                return title
            }
        }
        return nil
    }

    /// Scan up to the first 200 JSONL lines looking for a user
    /// message whose content isn't a `<local-command-…>` system
    /// caveat. Returns the first such text, trimmed and truncated to
    /// 80 characters. Bounded read because in pathological transcripts
    /// the first real prompt could be deep — but bounded so we don't
    /// pay megabytes of read for a label.
    private func readFirstUserPromptText(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        // Read a chunk (256 KB is enough for the first ~200 short
        // lines on typical transcripts; stops early if we find one).
        guard let data = try? handle.read(upToCount: 256 * 1024) else {
            return nil
        }
        guard let blob = String(data: data, encoding: .utf8) else {
            return nil
        }
        var lineCount = 0
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            lineCount += 1
            if lineCount > 200 { break }
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard obj["type"] as? String == "user" else { continue }
            // Pacer treats `<local-command-…>` and other system-meta
            // sleeves as not-real-user input — same heuristic as the
            // ccusage upstream's session-title sniffing.
            guard let text = extractUserText(from: obj),
                  !text.hasPrefix("<")
            else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return shortened(trimmed)
        }
        return nil
    }

    private func extractUserText(from line: [String: Any]) -> String? {
        guard let message = line["message"] as? [String: Any],
              let content = message["content"]
        else { return nil }
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text",
                   let t = item["text"] as? String {
                    return t
                }
            }
        }
        return nil
    }

    /// Trim to 80 chars (collapsing newlines to spaces) so a session
    /// row doesn't try to render a multi-line prompt.
    private func shortened(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        let limit = 80
        if collapsed.count <= limit { return collapsed }
        let truncated = collapsed.prefix(limit - 1)
        return truncated + "…"
    }
}
