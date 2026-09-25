import Foundation
import SwiftData

/// Assigns an account to history that predates the activation trail.
///
/// Every `TokenSample` written before Pacer started watching the login has
/// `accountId == nil`, and no amount of re-reading the transcripts can fix
/// that — Claude Code's JSONL never recorded which account was billed. The
/// only ways to fill it in are to *know* (one account has ever existed, so
/// every turn is that account's) or to be *told* (the user says which range
/// was which).
///
/// There is deliberately no third way. An automatic split by "whoever is
/// logged in now" or "whichever account was busiest" would produce a
/// per-account cost breakdown that looks authoritative and is fiction. An
/// unattributed row is visibly incomplete and invites the user to correct it;
/// a misattributed row is invisible and permanent.
@ScanActor
public enum AccountBackfill {
    public struct Result: Sendable, Equatable {
        public let samplesAttributed: Int
        public let accountId: String
        public let from: Date?
        public let through: Date?
    }

    /// The one inference that is sound rather than convenient: if exactly
    /// one account has ever been seen, every unattributed turn belongs to
    /// it. There is no other candidate for it to belong to.
    ///
    /// Runs on upgrade for the single-account majority so they get a
    /// complete per-account history without being asked a question they'd
    /// have no reason to understand. Users with more than one account get
    /// nothing automatic — they must assign ranges themselves via
    /// `assign(range:)`, because for them the answer is genuinely unknown.
    ///
    /// Returns nil when it declines to act (no accounts, or more than one).
    @discardableResult
    public static func backfillIfUnambiguous(
        context: ModelContext,
        now: Date = Date()
    ) throws -> Result? {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        guard accounts.count == 1, let only = accounts.first else { return nil }
        return try assign(
            accountId: only.id,
            from: nil,
            through: now,
            context: context,
            evidence: "only account ever observed",
            source: AccountActivation.sourceBackfill
        )
    }

    /// Attribute every currently-unattributed sample in `[from, through)` to
    /// `accountId`, and record the matching activation so the assignment is
    /// visible and reversible rather than an invisible column edit.
    ///
    /// Only touches rows where `accountId` is nil. An observed attribution
    /// always outranks a backfilled guess, so re-running this can never
    /// overwrite something Pacer actually watched happen.
    @discardableResult
    public static func assign(
        accountId: String,
        from: Date?,
        through: Date?,
        context: ModelContext,
        evidence: String?,
        source: String = AccountActivation.sourceManual
    ) throws -> Result {
        var descriptor = FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.accountId == nil }
        )
        descriptor.propertiesToFetch = [\.sampledAt]
        let candidates = try context.fetch(descriptor)

        var touched = 0
        for sample in candidates {
            if let from, sample.sampledAt < from { continue }
            if let through, sample.sampledAt >= through { continue }
            sample.accountId = accountId
            touched += 1
        }

        // Record the span even when it matched nothing, so the user's
        // statement about the period is retained and a later re-scan that
        // adds rows in that window inherits the same answer.
        context.insert(AccountActivation(
            accountId: accountId,
            startedAt: from ?? .distantPast,
            endedAt: through,
            rootPath: nil,
            source: source,
            evidence: evidence
        ))
        try context.save()

        return Result(
            samplesAttributed: touched,
            accountId: accountId,
            from: from,
            through: through
        )
    }

    /// Apply trail corrections to turns already stored: every sample carrying
    /// a correction's refuted account inside its range moves to the account
    /// the corrected trail names. Returns the moved samples so the caller can
    /// rebuild the rollups they feed.
    ///
    /// Only rows carrying the refuted account are touched, so turns that were
    /// already right stay put, and only where the corrected trail now names
    /// the right account for the default login — so a stretch the trail still
    /// gives to someone else (a manual range, say) is never moved by a
    /// correction whose range happens to cover it. A turn that a pinned profile bound to that same
    /// account could have written is left alone: samples do not record their
    /// root, and moving a pinned session's usage would be a new error.
    public static func restamp(
        _ corrections: [AccountTrailRecorder.Correction],
        trail: AccountTrail,
        context: ModelContext
    ) throws -> [TokenSample] {
        var moved: [TokenSample] = []
        for correction in corrections {
            let wrong: String? = correction.wrongAccount
            let from = correction.from
            let to = correction.to ?? .distantFuture
            let descriptor = FetchDescriptor<TokenSample>(predicate: #Predicate {
                $0.accountId == wrong && $0.sampledAt >= from && $0.sampledAt < to
            })
            for sample in try context.fetch(descriptor) {
                if trail.isPinned(correction.wrongAccount, at: sample.sampledAt) { continue }
                guard trail.accountId(at: sample.sampledAt) == correction.rightAccount else { continue }
                sample.accountId = correction.rightAccount
                moved.append(sample)
            }
        }
        return moved
    }

    /// How many turns still have no account, and the range they span —
    /// what a "you have unattributed history" prompt needs to say
    /// something true.
    public static func unattributedSummary(
        context: ModelContext
    ) throws -> (count: Int, earliest: Date?, latest: Date?) {
        var descriptor = FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.accountId == nil },
            sortBy: [SortDescriptor(\.sampledAt)]
        )
        descriptor.propertiesToFetch = [\.sampledAt]
        let rows = try context.fetch(descriptor)
        return (rows.count, rows.first?.sampledAt, rows.last?.sampledAt)
    }
}
