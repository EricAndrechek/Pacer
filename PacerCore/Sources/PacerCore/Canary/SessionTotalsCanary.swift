import Foundation

/// Judges one session: do Claude Code's own totals agree with Pacer's? (#353)
///
/// From 2026-09-23 to 10-22, Claude Code 2.1.280–2.1.306 stopped writing the
/// finished copy of subagent messages. Pacer kept the best copy there was, and
/// output was under-counted by about half for a month before anyone noticed.
/// Claude Code's own counters (`ClaudeSessionTotals`) showed it from the first
/// day: 2.3× the transcripts' output for sessions with subagents. This is the
/// check that would have said so. Pure: `DataCanary` gathers the inputs.
///
/// **Like for like.** Ratios are Claude Code's number over Pacer's. Claude
/// Code's counters also hold its own background calls, which write no
/// transcript, so its numbers run *above* the transcripts' even when nothing is
/// wrong (a real install, healthy sessions: cache reads 1.0–1.5×, input 2× to
/// 1000×, Haiku output 100–2000×). Hence:
/// - **output** is judged both ways. Above: Claude Code's output on every model
///   but its small one against all of Pacer's output. That is the direction the
///   09-23 defect went (6.9× on a 2.1.306 session of the same install). Below:
///   all of Claude Code's output against all of Pacer's.
///
///   Above is judged loosely: more than `outputAboveTolerance` *and* at least
///   `outputAboveMinimumGap` tokens, because Claude Code also makes calls on
///   the main model whose output reaches no transcript: a compaction (it
///   leaves a `compact_boundary` line and no usage; ~4–8k output each), a
///   "while you were away" recap (an `away_summary` line; ~110 each), and
///   others that leave nothing at all. Claude Code's own request log
///   (`api-request` lines) lists exactly the requests the transcript holds
///   usage for; these calls are not in it either. Measured 2026-11-23 against
///   the counters Claude Code writes into its transcripts (`cost-state`
///   lines) on one install: 39 sessions written wholly by 2.1.307+ ran
///   1.000–1.095. 14 of the 15 with no compaction or recap ran exactly 1.000;
///   the 15th, an SDK session, ran 1.095. A session with 15 compactions ran
///   1.128. Pacer's rows equalled a hand count of the transcripts, so the
///   excess is not something Pacer dropped. Sessions with the 09-23 defect's
///   turns ran up to 10.4×: of the 42 above 1.13, 38 were above 1.25, with
///   gaps of 80k tokens or more. A 2–10% excess (Sentry PACER-28) is these
///   calls, not a lost transcript.
/// - **input, cache reads, cache writes** are judged only below: Pacer holding
///   more than Claude Code counted means Pacer counted something twice. Above
///   is Claude Code's own calls, and says nothing.
/// Pacer's 5-minute and 1-hour cache writes are summed against Claude Code's
/// one number.
public enum SessionTotalsCanary {

    public enum TokenKind: String, CaseIterable, Sendable, Comparable {
        case input
        case output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"

        public static func < (a: TokenKind, b: TokenKind) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// Pacer's side, from the `SessionInfo` rollup.
    public struct PacerTotals: Sendable, Equatable {
        public let inputTokens: Int64
        public let outputTokens: Int64
        public let cacheReadTokens: Int64
        /// 5-minute plus 1-hour writes.
        public let cacheWriteTokens: Int64
        public let firstSeenAt: Date
        public let lastSeenAt: Date
        /// The Claude Code version the session's latest turns were written by.
        public let ccVersion: String?

        public init(inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64,
                    cacheWriteTokens: Int64, firstSeenAt: Date, lastSeenAt: Date,
                    ccVersion: String? = nil) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
            self.ccVersion = ccVersion
        }

        public init(_ info: SessionInfo) {
            self.init(
                inputTokens: info.cumulativeInputTokens,
                outputTokens: info.cumulativeOutputTokens,
                cacheReadTokens: info.cumulativeCacheReadTokens,
                cacheWriteTokens: info.cumulativeCacheCreation5mTokens
                    + info.cumulativeCacheCreation1hTokens,
                firstSeenAt: info.firstSeenAt,
                lastSeenAt: info.lastSeenAt,
                ccVersion: info.ccVersion)
        }
    }

    public struct Policy: Sendable, Equatable {
        /// A ratio this far from 1 is a mismatch, except output above 1.
        public var tolerance: Double
        /// Output above 1 is a mismatch only this far above, and only with a gap
        /// of at least `outputAboveMinimumGap` tokens: Claude Code's
        /// untranscribed compactions and recaps put healthy sessions up to ~1.13
        /// (the type's comment has the measurements).
        public var outputAboveTolerance: Double
        /// A few compactions' output. Without it, one compaction in a session
        /// near `minimumOutputTokens` would cross any ratio worth using.
        public var outputAboveMinimumGap: Int64
        /// Sessions smaller than this, in output on either side, are not
        /// judged: one compaction or one stray turn moves a small session's
        /// ratio by more than any tolerance worth having.
        public var minimumOutputTokens: Int64
        /// How long Claude Code's save and every transcript of the session must
        /// have been still.
        public var quietPeriod: TimeInterval
        /// Only sessions that began and were saved this recently. Older ones
        /// were judged on earlier days (or before the canary existed, and are
        /// history: the 09-23 defect is known, and re-reporting it would read
        /// as a new one), and a session that runs for weeks spans versions.
        public var lookback: TimeInterval
        /// The longest the saving process may have run before the session's
        /// first turn. Longer, and the counters likely hold other work first
        /// (another session, a `/resume`), so they are not this session's.
        /// A `/clear` is not such work: it resets the counters and the start
        /// time, so the lead-in counts from the clear (`ClaudeSessionTotals`).
        public var maxLeadIn: TimeInterval
        /// Slack for the two clocks: Claude Code's `Date.now()` and the
        /// transcript's timestamps, written by the same process.
        public var clockSlack: TimeInterval

        public init(tolerance: Double = 0.02, outputAboveTolerance: Double = 0.25,
                    outputAboveMinimumGap: Int64 = 25_000, minimumOutputTokens: Int64 = 20_000,
                    quietPeriod: TimeInterval = 15 * 60, lookback: TimeInterval = 7 * 86_400,
                    maxLeadIn: TimeInterval = 30 * 60, clockSlack: TimeInterval = 2 * 60) {
            self.tolerance = tolerance
            self.outputAboveTolerance = outputAboveTolerance
            self.outputAboveMinimumGap = outputAboveMinimumGap
            self.minimumOutputTokens = minimumOutputTokens
            self.quietPeriod = quietPeriod
            self.lookback = lookback
            self.maxLeadIn = maxLeadIn
            self.clockSlack = clockSlack
        }

        public static let standard = Policy()
    }

    /// Why a session was not judged. Raw values go into the local log only.
    public enum SkipReason: String, CaseIterable, Sendable, Comparable {
        /// Claude Code wrote no start time or duration.
        case noTiming = "no_timing"
        /// Pacer has no rows for the session (often a session with no turns).
        case noSession = "no_session"
        case tooOld = "too_old"
        /// The session's first turn predates the process that saved the
        /// counters: a resume, whose counters may not cover the earlier part.
        case beganBeforeProcess = "began_before_process"
        /// The process ran longer than `maxLeadIn` before the session began.
        case ranOtherWorkFirst = "ran_other_work_first"
        /// Pacer has turns after the save, which the counters cannot hold.
        case turnsAfterSave = "turns_after_save"
        /// Saved, or a transcript written, within `quietPeriod`.
        case notFinished = "not_finished"
        /// No transcript of the session found on disk, so ingestion cannot be
        /// confirmed.
        case noTranscript = "no_transcript"
        /// A transcript Pacer has not read to its end.
        case notIngested = "not_ingested"
        case tooSmall = "too_small"

        public static func < (a: SkipReason, b: SkipReason) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// The session's transcripts on disk against Pacer's cursors.
    public struct TranscriptState: Sendable, Equatable {
        /// Transcript files found: the session's own and its subagents'.
        public var files: Int
        /// The newest modification among them.
        public var newestModification: Date?
        /// Files Pacer's cursor has not reached the end of.
        public var filesBehind: Int
        /// Files with no cursor at all: never read.
        public var filesUnread: Int

        public init(files: Int = 0, newestModification: Date? = nil,
                    filesBehind: Int = 0, filesUnread: Int = 0) {
            self.files = files
            self.newestModification = newestModification
            self.filesBehind = filesBehind
            self.filesUnread = filesUnread
        }
    }

    /// Whether the session can be judged at all: finished, fully ingested,
    /// and with counters that cover exactly it. nil means yes. The comparison
    /// itself can still decline a session as too small (`compare`).
    ///
    /// **Finished and ingested**, the rule: Claude Code saved the counters at
    /// least `quietPeriod` ago and no transcript of the session has been
    /// written since then either, and every one of those transcripts has a
    /// Pacer cursor at its end. The cursor is the proof that the scan caught
    /// up, whatever the scan's own timing did; the quiet period is what makes
    /// the counters final.
    ///
    /// **Same span**: the counters cover the saving process's life, `startedAt`
    /// to `savedAt`. Pacer's turns for the session must sit inside it, and
    /// begin within `maxLeadIn` of its start.
    public static func eligibility(
        claude: ClaudeSessionTotals,
        pacer: PacerTotals?,
        transcripts: TranscriptState,
        now: Date,
        policy: Policy = .standard
    ) -> SkipReason? {
        if let skip = spanSkip(claude: claude, pacer: pacer, now: now, policy: policy) {
            return skip
        }
        return transcriptSkip(transcripts, now: now, policy: policy)
    }

    /// The part of `eligibility` that needs no disk: timing and span.
    public static func spanSkip(
        claude: ClaudeSessionTotals,
        pacer: PacerTotals?,
        now: Date,
        policy: Policy = .standard
    ) -> SkipReason? {
        guard let start = claude.startedAt, let saved = claude.savedAt else { return .noTiming }
        guard let pacer else { return .noSession }
        let oldest = now.addingTimeInterval(-policy.lookback)
        if saved < oldest || pacer.firstSeenAt < oldest { return .tooOld }
        if pacer.firstSeenAt < start.addingTimeInterval(-policy.clockSlack) {
            return .beganBeforeProcess
        }
        if pacer.firstSeenAt.timeIntervalSince(start) > policy.maxLeadIn {
            return .ranOtherWorkFirst
        }
        if pacer.lastSeenAt > saved.addingTimeInterval(policy.clockSlack) {
            return .turnsAfterSave
        }
        if now.timeIntervalSince(saved) < policy.quietPeriod { return .notFinished }
        return nil
    }

    /// The part of `eligibility` that the transcripts on disk decide.
    public static func transcriptSkip(
        _ transcripts: TranscriptState,
        now: Date,
        policy: Policy = .standard
    ) -> SkipReason? {
        guard transcripts.files > 0 else { return .noTranscript }
        if let newest = transcripts.newestModification,
           now.timeIntervalSince(newest) < policy.quietPeriod {
            return .notFinished
        }
        if transcripts.filesBehind > 0 || transcripts.filesUnread > 0 { return .notIngested }
        return nil
    }

    public struct Mismatch: Sendable, Equatable {
        public let kind: TokenKind
        /// Claude Code's number over Pacer's, as judged.
        public let ratio: Double
        public var band: String { SessionTotalsCanary.ratioBand(ratio) }

        public init(kind: TokenKind, ratio: Double) {
            self.kind = kind
            self.ratio = ratio
        }
    }

    public struct Comparison: Sendable, Equatable {
        /// Claude Code over Pacer per kind. Output is the like-for-like ratio
        /// (every model but the small one); the rest are totals.
        public let ratios: [TokenKind: Double]
        public let mismatches: [Mismatch]
        public var matched: Bool { mismatches.isEmpty }
    }

    /// Compare one eligible session. nil when it is too small to judge.
    public static func compare(
        claude: ClaudeSessionTotals,
        pacer: PacerTotals,
        policy: Policy = .standard
    ) -> Comparison? {
        let likeForLike = claude.outputTokensExcludingSmallModel
        guard max(likeForLike, pacer.outputTokens) >= policy.minimumOutputTokens else { return nil }

        let outputAbove = ratio(likeForLike, pacer.outputTokens)
        let outputBelow = ratio(claude.outputTokens, pacer.outputTokens)
        let ratios: [TokenKind: Double] = [
            .input: ratio(claude.inputTokens, pacer.inputTokens),
            .output: outputAbove,
            .cacheRead: ratio(claude.cacheReadTokens, pacer.cacheReadTokens),
            .cacheWrite: ratio(claude.cacheCreationTokens, pacer.cacheWriteTokens),
        ]

        let low = 1 - policy.tolerance
        // Loose above: Claude Code's untranscribed main-model calls (see the
        // type's comment) must not read as Pacer losing output.
        let outputHigh = 1 + policy.outputAboveTolerance
        let outputGap = likeForLike - pacer.outputTokens
        var mismatches: [Mismatch] = []
        for kind in TokenKind.allCases {
            switch kind {
            case .output:
                if outputAbove > outputHigh, outputGap >= policy.outputAboveMinimumGap {
                    mismatches.append(Mismatch(kind: .output, ratio: outputAbove))
                } else if outputBelow < low {
                    mismatches.append(Mismatch(kind: .output, ratio: outputBelow))
                }
            case .input, .cacheRead, .cacheWrite:
                if let r = ratios[kind], r < low {
                    mismatches.append(Mismatch(kind: kind, ratio: r))
                }
            }
        }
        return Comparison(ratios: ratios, mismatches: mismatches)
    }

    /// Claude Code's number over Pacer's; 1 when both are zero, infinite when
    /// only Pacer's is.
    public static func ratio(_ claude: Int64, _ pacer: Int64) -> Double {
        guard pacer > 0 else { return claude > 0 ? .infinity : 1 }
        return Double(claude) / Double(pacer)
    }

    /// A ratio as a band, for telemetry: coarse enough to group one upstream
    /// defect into one issue, fine enough to tell a lost half from a stray
    /// percent. Claude Code over Pacer, so above 1 is Pacer under-counting.
    /// Output above is only reported past 1.25, so the bands up there tell a
    /// partial loss (`1.25-2`) from most of a session's output gone (`>2`).
    public static func ratioBand(_ ratio: Double) -> String {
        switch ratio {
        case ..<0.5: return "<0.5"
        case ..<0.9: return "0.5-0.9"
        case ..<0.98: return "0.9-0.98"
        case ...1.02: return "0.98-1.02"
        case ...1.1: return "1.02-1.1"
        case ...1.25: return "1.1-1.25"
        case ...2: return "1.25-2"
        default: return ">2"
        }
    }
}
