import Foundation

/// Judges one session: does Pacer hold everything Claude Code made for it? (#353)
///
/// From 2026-09-23 to 10-22, Claude Code 2.1.280–2.1.306 stopped writing the
/// finished copy of subagent messages. Pacer kept the best copy there was, and
/// output was under-counted by about half for a month before anyone noticed.
/// Claude Code's own counters (`ClaudeSessionTotals`) showed it from the first
/// day: 2.3× the transcripts' output for sessions with subagents. Pure:
/// `DataCanary` gathers the inputs. Two checks:
///
/// **Requests, exact.** Claude Code logs every API request it makes
/// (`api-request` lines) and tags each usage line with the request it answers
/// (`requestRef`). Every answered request must have a Pacer row; one missing
/// is a mismatch (`TranscriptEvidence`). This is the check that sees a lost
/// file, a line shape the parser stopped reading, or a dedup that merged two
/// requests, at any size. It does not count logged requests with no answer:
/// 1.8% of the logged requests on one install (7,166 of 391,785) got no
/// response line at all (failed, retried, interrupted), which is Claude Code's
/// and not a loss. Measured 2026-11-23 on 329 fully ingested sessions of one
/// install: 386,248 answered requests, every one in the store (1,399 of them
/// under another session, as a resume's replay).
///
/// **Tokens, a backstop.** Ratios are Claude Code's number over Pacer's.
/// Claude Code's counters also hold its own calls, which write no usage to any
/// transcript, so its numbers run *above* the transcripts' even when nothing
/// is wrong (cache reads 1.0–1.5×, input 2× to 1000×, Haiku output 100–2000×).
/// Hence:
/// - **output** is judged both ways. Above: Claude Code's output on every model
///   but its small one against all of Pacer's output, which is the direction
///   the 09-23 defect went (its requests were all there; their output was
///   not, so only this check sees it). Below: all of Claude Code's output
///   against all of Pacer's.
///
///   Above is allowed what the transcripts say Claude Code spent off the
///   record, on top of `tolerance`: each compaction (a `compact_boundary`
///   line; 4.4–7.6k output measured, budgeted 10k) and each "while you were
///   away" recap (an `away_summary` line; 80–310 measured, budgeted 500)
///   inside the counters' window, plus `desktopTolerance` for a session Claude
///   Desktop wrote, which makes calls that leave no line at all (one Desktop
///   session: 9.5% over with all 112 requests present; four others exact).
///   Measured 2026-11-23 against the counters Claude Code writes into its
///   transcripts (`cost-state` lines): of 66 sessions written wholly by
///   2.1.307+, none crosses that allowance above (the flat 2% the canary
///   started with crossed on 9, Sentry PACER-28; three more fall below 0.98
///   only because their counters stop days before their transcripts, which
///   `spanSkip` rules out); of the 42 sessions with 09-23-era turns above
///   1.13, all 42 cross it.
/// - **input, cache reads, cache writes** are judged only below: Pacer holding
///   more than Claude Code counted means Pacer counted something twice. Above
///   is Claude Code's own calls, and says nothing.
/// Pacer's 5-minute and 1-hour cache writes are summed against Claude Code's
/// one number.
public enum SessionTotalsCanary {

    /// What a mismatch is in. Every case but `requests` is a token count.
    public enum TokenKind: String, CaseIterable, Sendable, Comparable {
        case input
        case output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        /// Requests Claude Code answered that Pacer has no row for.
        case requests

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

        /// A session Pacer has no rows for: nothing, placed in the counters'
        /// own window so no span rule trips on it.
        public static func nothing(during claude: ClaudeSessionTotals) -> PacerTotals {
            let at = claude.startedAt ?? Date.distantPast
            return PacerTotals(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                               cacheWriteTokens: 0, firstSeenAt: at, lastSeenAt: at)
        }
    }

    /// What the session's transcripts say on their own, read by `DataCanary`.
    public struct TranscriptEvidence: Sendable, Equatable {
        /// Requests Claude Code logged and answered with a usage line, across
        /// every transcript of the session. 0 for transcripts written before
        /// Claude Code logged requests: the request check then has nothing to
        /// judge.
        public var answeredRequests: Int
        /// Of those, how many have no Pacer row, in this session or any other
        /// (a resume replays a turn under a new session id; one copy is kept).
        /// nil when the store could not be asked: not judged.
        public var missingRequests: Int?
        /// Logged with no answer at all (failed, retried, interrupted). Claude
        /// Code's, not a loss; for the local log.
        public var unansweredRequests: Int
        /// Inside the counters' window: main-model calls whose usage reaches no
        /// transcript, each leaving one line.
        public var compactions: Int
        public var recaps: Int
        /// Claude Desktop wrote the session (`entrypoint` `claude-desktop`).
        public var desktop: Bool

        public init(answeredRequests: Int = 0, missingRequests: Int? = 0,
                    unansweredRequests: Int = 0, compactions: Int = 0, recaps: Int = 0,
                    desktop: Bool = false) {
            self.answeredRequests = answeredRequests
            self.missingRequests = missingRequests
            self.unansweredRequests = unansweredRequests
            self.compactions = compactions
            self.recaps = recaps
            self.desktop = desktop
        }

        public static let none = TranscriptEvidence()
    }

    public struct Policy: Sendable, Equatable {
        /// A ratio this far from 1 is a mismatch. Output above 1 is also
        /// allowed what the transcripts' markers explain (below).
        public var tolerance: Double
        /// Output above Pacer's allowed per compaction in the window. Measured
        /// 4.4–7.6k per compaction (five sessions with compactions and no
        /// recaps), ~9.4k implied for one with recaps too. Not more: in a
        /// session that compacts 25 times, every 10k of slack per compaction
        /// is 250k of lost output the check would not see.
        public var compactionOutputAllowance: Int64
        /// Output allowed per recap in the window: 80–310 measured, the median
        /// ~120, a few above 500 only where 2% of the session covered them.
        public var recapOutputAllowance: Int64
        /// Extra output tolerance for a session Claude Desktop wrote: it makes
        /// main-model calls that leave no line (9.5% on one session whose 112
        /// requests were all present). 10 points rather than the 7.5 that
        /// session needed: one sample, and the request check still covers
        /// lost requests there.
        public var desktopTolerance: Double
        /// Answered requests Pacer may lack before it is a mismatch. Zero: on
        /// 329 real sessions none was missing.
        public var maxMissingRequests: Int
        /// Sessions smaller than this, in output on either side, are not judged
        /// on tokens: one stray turn moves a small session's ratio by more than
        /// any tolerance worth having. Requests are judged at any size, and so
        /// is a session Pacer holds no output for.
        public var minimumOutputTokens: Int64
        /// The most transcript bytes the canary reads for one session. Larger
        /// sessions are skipped (`tooLarge`).
        public var maxTranscriptBytes: Int64
        /// The most transcript bytes one run reads; the rest wait for the next
        /// run (`overBudget`). The first run after an upgrade finds a week of
        /// unjudged sessions at once, where a day normally brings a few. 1 GB:
        /// the reader went through 1,976 MB of real transcripts in 38.7 s (a
        /// debug build), so about 20 s of one utility thread at most per day.
        public var maxBytesPerRun: Int64
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

        public init(tolerance: Double = 0.02, compactionOutputAllowance: Int64 = 10_000,
                    recapOutputAllowance: Int64 = 500, desktopTolerance: Double = 0.10,
                    maxMissingRequests: Int = 0, minimumOutputTokens: Int64 = 20_000,
                    maxTranscriptBytes: Int64 = 2 << 30, maxBytesPerRun: Int64 = 1 << 30,
                    quietPeriod: TimeInterval = 15 * 60, lookback: TimeInterval = 7 * 86_400,
                    maxLeadIn: TimeInterval = 30 * 60, clockSlack: TimeInterval = 2 * 60) {
            self.tolerance = tolerance
            self.compactionOutputAllowance = compactionOutputAllowance
            self.recapOutputAllowance = recapOutputAllowance
            self.desktopTolerance = desktopTolerance
            self.maxMissingRequests = maxMissingRequests
            self.minimumOutputTokens = minimumOutputTokens
            self.maxTranscriptBytes = maxTranscriptBytes
            self.maxBytesPerRun = maxBytesPerRun
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
        /// Pacer has no rows for the session and no transcript of it was found
        /// (often a session with no turns).
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
        /// More transcript than `maxTranscriptBytes` to read.
        case tooLarge = "too_large"
        /// This run had read `maxBytesPerRun` already: judged on a later run.
        case overBudget = "over_budget"
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

    /// Whether the session can be judged on its tokens: finished, fully
    /// ingested, and with counters that cover exactly it. nil means yes. The
    /// comparison itself can still decline a session as too small (`compare`).
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
    /// begin within `maxLeadIn` of its start. A session Pacer has no rows for
    /// has nothing to misplace (`spanSkip`).
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

    /// The part of `eligibility` that needs no disk: timing and span. nil for
    /// a session Pacer has no rows for, once the counters are old enough to
    /// be final: it is judged as Pacer holding nothing.
    public static func spanSkip(
        claude: ClaudeSessionTotals,
        pacer: PacerTotals?,
        now: Date,
        policy: Policy = .standard
    ) -> SkipReason? {
        guard let start = claude.startedAt, let saved = claude.savedAt else { return .noTiming }
        let oldest = now.addingTimeInterval(-policy.lookback)
        if saved < oldest { return .tooOld }
        if let pacer {
            if pacer.firstSeenAt < oldest { return .tooOld }
            if pacer.firstSeenAt < start.addingTimeInterval(-policy.clockSlack) {
                return .beganBeforeProcess
            }
            if pacer.firstSeenAt.timeIntervalSince(start) > policy.maxLeadIn {
                return .ranOtherWorkFirst
            }
            if pacer.lastSeenAt > saved.addingTimeInterval(policy.clockSlack) {
                return .turnsAfterSave
            }
        }
        if now.timeIntervalSince(saved) < policy.quietPeriod { return .notFinished }
        return nil
    }

    /// The part of `eligibility` that the transcripts on disk decide. Both
    /// checks need it: a transcript still being written or not yet read
    /// proves nothing either way.
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
        /// Claude Code's number over Pacer's, as judged: for `requests`,
        /// answered requests over the ones Pacer has.
        public let ratio: Double
        public var band: String { SessionTotalsCanary.ratioBand(ratio) }

        public init(kind: TokenKind, ratio: Double) {
            self.kind = kind
            self.ratio = ratio
        }
    }

    public struct Comparison: Sendable, Equatable {
        /// Claude Code over Pacer per kind judged. Output is the like-for-like
        /// ratio (every model but the small one); requests are answered over
        /// held; the rest are totals.
        public let ratios: [TokenKind: Double]
        public let mismatches: [Mismatch]
        public var matched: Bool { mismatches.isEmpty }
    }

    /// Output above Pacer's that the transcripts explain (the type's comment).
    public static func outputAllowance(
        pacerOutput: Int64, evidence: TranscriptEvidence, policy: Policy = .standard
    ) -> Double {
        let tolerance = policy.tolerance + (evidence.desktop ? policy.desktopTolerance : 0)
        return tolerance * Double(pacerOutput)
            + Double(policy.compactionOutputAllowance) * Double(evidence.compactions)
            + Double(policy.recapOutputAllowance) * Double(evidence.recaps)
    }

    /// Compare one session. `judgeTokens` is false when the counters do not
    /// cover exactly this session (`spanSkip`): the request check, which needs
    /// only the transcripts and the store, still runs. nil when nothing could
    /// be judged.
    public static func compare(
        claude: ClaudeSessionTotals,
        pacer: PacerTotals,
        evidence: TranscriptEvidence = .none,
        judgeTokens: Bool = true,
        policy: Policy = .standard
    ) -> Comparison? {
        var ratios: [TokenKind: Double] = [:]
        var mismatches: [Mismatch] = []
        let low = 1 - policy.tolerance

        let requestsJudged = evidence.answeredRequests > 0 && evidence.missingRequests != nil
        if requestsJudged, let missing = evidence.missingRequests {
            let answered = evidence.answeredRequests
            let held = max(0, answered - missing)
            let r = ratio(Int64(answered), Int64(held))
            ratios[.requests] = r
            if missing > policy.maxMissingRequests {
                mismatches.append(Mismatch(kind: .requests, ratio: r))
            }
        }

        let likeForLike = claude.outputTokensExcludingSmallModel
        let allowance = outputAllowance(pacerOutput: pacer.outputTokens, evidence: evidence,
                                        policy: policy)
        // Main-model output and no turn of Pacer's: a loss at any size, unless
        // the session's markers explain it (a resume whose rows stayed under
        // the old session id, then a compaction).
        let nothingHeld = pacer.outputTokens == 0 && Double(likeForLike) > allowance
        let tokensJudged = judgeTokens
            && (nothingHeld || max(likeForLike, pacer.outputTokens) >= policy.minimumOutputTokens)
        if tokensJudged {
            let outputAbove = ratio(likeForLike, pacer.outputTokens)
            let outputBelow = ratio(claude.outputTokens, pacer.outputTokens)
            ratios[.input] = ratio(claude.inputTokens, pacer.inputTokens)
            ratios[.output] = outputAbove
            ratios[.cacheRead] = ratio(claude.cacheReadTokens, pacer.cacheReadTokens)
            ratios[.cacheWrite] = ratio(claude.cacheCreationTokens, pacer.cacheWriteTokens)

            let excess = Double(likeForLike - pacer.outputTokens)
            if excess > allowance {
                mismatches.append(Mismatch(kind: .output, ratio: outputAbove))
            } else if outputBelow < low {
                mismatches.append(Mismatch(kind: .output, ratio: outputBelow))
            }
            for kind in [TokenKind.input, .cacheRead, .cacheWrite] {
                if let r = ratios[kind], r < low {
                    mismatches.append(Mismatch(kind: kind, ratio: r))
                }
            }
        }
        guard requestsJudged || tokensJudged else { return nil }
        mismatches.sort { $0.kind < $1.kind }
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
