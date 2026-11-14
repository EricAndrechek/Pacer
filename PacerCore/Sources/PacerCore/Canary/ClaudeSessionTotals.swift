import Foundation

/// Claude Code's own token totals for one session, as it keeps them in its
/// global config (#353).
///
/// Claude Code's `.claude.json` holds, per project (`projects["<path>"]`), the
/// counters of the last process that saved there: `lastSessionId`, the four
/// `lastTotal…Tokens`, `lastModelUsage` per model, `lastStartTime` (ms since
/// 1970) and `lastDuration` (ms). Only the latest session per project is kept,
/// so this is a canary, not a ledger: enough to notice, within a day, that the
/// transcripts Pacer reads stopped matching what Claude Code itself counted.
///
/// **What the counters cover** (measured on a real install, 2026-11-13):
/// - every API call the process made, subagents included. Subagent transcripts
///   carry the parent's `sessionId`, so Pacer's sums for that id include them
///   too: like for like.
/// - also Claude Code's own background calls, which write no transcript:
///   titles and summaries on its small model (Haiku), and classifier and
///   suggestion calls on the main model that re-read the cached context. That
///   is why only output is compared both ways (`SessionTotalsCanary`).
/// - the process's whole life, from `lastStartTime` for `lastDuration`. A
///   session that a long-lived process resumed, or one it ran after other
///   work, is not like for like; `SessionTotalsCanary.eligibility` tells.
/// - **not** what came before a `/clear`. `/clear` saves the outgoing
///   session's counters under its own id, then resets them and the start
///   time for the new one (2.1.325's `/clear` does both). A real 2.1.312
///   session begun by `/clear`, 2.5 min after the previous session's last
///   turn in the same process, had `lastStartTime` 0.3 s *after* the
///   `/clear` line, and matched its own transcripts (output 1.010, cache
///   writes 1.001) where the previous session's turns would have made its
///   output 1.66. So a session begun by `/clear` is like for like, and is
///   judged like any other: it is not a reason to skip.
///
/// The project key (a path) is read and dropped: nothing here keeps it.
public struct ClaudeSessionTotals: Sendable, Equatable {
    public let sessionId: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    /// One number: Claude Code does not split 5-minute and 1-hour writes.
    public let cacheCreationTokens: Int64
    /// `lastModelUsage[model].outputTokens`, by model id as Claude Code wrote
    /// it (`[1m]` suffixes and all).
    public let outputTokensByModel: [String: Int64]
    /// When the process that saved these counters started; nil if not written.
    public let startedAt: Date?
    /// How long that process had run when it saved them.
    public let duration: TimeInterval?

    public init(
        sessionId: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheCreationTokens: Int64,
        outputTokensByModel: [String: Int64] = [:],
        startedAt: Date? = nil,
        duration: TimeInterval? = nil
    ) {
        self.sessionId = sessionId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.outputTokensByModel = outputTokensByModel
        self.startedAt = startedAt
        self.duration = duration
    }

    /// When the counters were saved: the end of the window they cover.
    public var savedAt: Date? {
        guard let startedAt, let duration else { return nil }
        return startedAt.addingTimeInterval(duration)
    }

    /// Output on every model but Claude Code's small one.
    ///
    /// Claude Code runs its own titles, summaries and other housekeeping on
    /// its small fast model (Haiku unless the user configured another), and
    /// those calls write no transcript: on a real install they were 100–2000×
    /// the Haiku output any transcript held. Leaving that model out is what
    /// makes the output comparison like for like. The cost is that a defect
    /// only in Haiku subagents would go unseen; every other model's still shows.
    public var outputTokensExcludingSmallModel: Int64 {
        let small = outputTokensByModel
            .filter { Self.isSmallFastModel($0.key) }
            .reduce(Int64(0)) { $0 + $1.value }
        return max(0, outputTokens - small)
    }

    /// Whether `model` is Claude Code's default small fast model.
    public static func isSmallFastModel(_ model: String) -> Bool {
        model.lowercased().contains("haiku")
    }
}

/// Finds and reads Claude Code's global configs for the canary.
public enum ClaudeSessionTotalsReader {

    /// Every project's latest session totals in one config file's contents.
    /// Entries without a session id or without the four totals are skipped;
    /// a file that is not JSON gives nothing. Never throws: a config caught
    /// mid-rewrite is an ordinary state, and the next run reads it again.
    public static func parse(_ data: Data) -> [ClaudeSessionTotals] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [] }
        var out: [ClaudeSessionTotals] = []
        for case let entry as [String: Any] in projects.values {
            guard let sessionId = entry["lastSessionId"] as? String, !sessionId.isEmpty,
                  let input = int64(entry["lastTotalInputTokens"]),
                  let output = int64(entry["lastTotalOutputTokens"]),
                  let cacheRead = int64(entry["lastTotalCacheReadInputTokens"]),
                  let cacheCreation = int64(entry["lastTotalCacheCreationInputTokens"])
            else { continue }
            var byModel: [String: Int64] = [:]
            if let usage = entry["lastModelUsage"] as? [String: Any] {
                for (model, value) in usage {
                    guard let fields = value as? [String: Any],
                          let tokens = int64(fields["outputTokens"]) else { continue }
                    byModel[model, default: 0] += tokens
                }
            }
            let startedAt = double(entry["lastStartTime"])
                .map { Date(timeIntervalSince1970: $0 / 1000) }
            let duration = double(entry["lastDuration"]).map { $0 / 1000 }
            out.append(ClaudeSessionTotals(
                sessionId: sessionId,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation,
                outputTokensByModel: byModel,
                startedAt: startedAt,
                duration: duration))
        }
        return out
    }

    /// `parse` of the file at `url`; empty when it cannot be read.
    public static func read(configAt url: URL) -> [ClaudeSessionTotals] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    /// The global config of every data root Pacer scans, each once.
    ///
    /// Where Claude Code keeps it is `ActiveAccountObserver.configCandidates`:
    /// `~/.claude.json` beside the home layout's `~/.claude` (and its XDG
    /// sibling), `<root>/.claude.json` inside any root a `CLAUDE_CONFIG_DIR`
    /// names — a switcher's session profile, a Desktop install's own config
    /// directory, an agent-mode session's `.claude`. `homeLayout` is false
    /// when Pacer itself runs with `CLAUDE_CONFIG_DIR`, which is exclusive:
    /// the home config then belongs to nothing being scanned.
    public static func configFiles(
        roots: [ClaudePathResolver.ResolvedRoot],
        homeLayout: Bool,
        homeDirectory: URL,
        observer: ActiveAccountObserver = ActiveAccountObserver()
    ) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        func add(_ found: (url: URL, modifiedAt: Date)?) {
            guard let url = found?.url, seen.insert(url.canonicalPathURL.path).inserted else { return }
            out.append(url)
        }
        if homeLayout {
            add(observer.currentConfig(forRoot: nil, homeDirectory: homeDirectory))
        }
        for root in roots {
            add(observer.currentConfig(forRoot: root.root, homeDirectory: homeDirectory))
        }
        return out
    }

    private static func int64(_ value: Any?) -> Int64? {
        // JSONSerialization hands numbers back as NSNumber, integer or not.
        (value as? NSNumber).map { $0.int64Value }
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber).map { $0.doubleValue }
    }
}
