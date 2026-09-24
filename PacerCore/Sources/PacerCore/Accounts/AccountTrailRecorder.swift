import Foundation
import SwiftData

/// Keeps the `AccountActivation` table in step with what's actually logged in.
///
/// Called once per scan cycle. Cheap by construction: the mtime gate means a
/// cycle where nothing changed does one `stat` per root and touches neither
/// the JSON parser nor the store.
///
/// The write rule is narrow on purpose — an activation is only ever closed by
/// a *successful* read showing a *different* account. An unreadable config, a
/// missing `oauthAccount`, a file caught mid-rewrite: all leave the trail
/// untouched. A false switch would split one account's session across two
/// accounts and there is no way to detect that afterwards, whereas a missed
/// switch self-corrects on the next cycle. The asymmetry is deliberate.
@ScanActor
public final class AccountTrailRecorder {
    private let context: ModelContext
    private let observer: ActiveAccountObserver
    private let homeDirectory: URL

    /// Last-seen modification date per config path, so an unchanged file
    /// costs a `stat` rather than a 180 KB parse.
    private var lastModified: [String: Date] = [:]
    /// Cached trail, invalidated whenever this recorder writes.
    private var cachedTrail: AccountTrail?

    /// A retroactive edit to the default login's trail: turns stamped
    /// `wrongAccount` in `[from, to)` belong to `rightAccount`. Samples are
    /// attributed as they are inserted, so any edit that reaches into the past
    /// leaves already-stored rows behind; the scan loop re-stamps them from
    /// these.
    public struct Correction: Sendable, Equatable {
        public let from: Date
        /// nil means "through now" — the corrected span is still open.
        public let to: Date?
        public let wrongAccount: String
        public let rightAccount: String
    }

    /// A config observation held back because the credential disagreed with
    /// it and had not been read since the file changed. Carries the instant
    /// it was first seen so that, if it turns out to be a real switch, the
    /// span starts where the switch happened rather than where it was
    /// confirmed.
    private var pendingObservation: (observation: ActiveAccountObserver.Observation, firstSeen: Date, fileModified: Date)?
    /// Set by `poll` when a disagreeing observation is waiting on a fresh
    /// keychain read; the caller asks the poller for one.
    public private(set) var needsCredentialCheck = false
    /// Corrections produced since the caller last drained them.
    private var corrections: [Correction] = []
    /// The account last rejected as a stale config write, so the log says
    /// so once per episode rather than on every rewrite of the file.
    private var lastRejectedKey: String?

    /// How long an observation may wait for the credential to confirm or
    /// refute it before it is accepted anyway. Long enough for a throttled
    /// keychain re-read to land; short enough that an unreadable keychain
    /// cannot freeze attribution. Acceptance is backdated to first sighting
    /// either way, so the wait costs nothing in accuracy.
    public static let credentialVerificationTimeout: TimeInterval = 180

    public init(
        context: ModelContext,
        observer: ActiveAccountObserver = ActiveAccountObserver(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.context = context
        self.observer = observer
        self.homeDirectory = homeDirectory
    }

    /// Poll every pinned session profile, so a root that a terminal has
    /// bound to a second account is attributed to that account rather than
    /// to whoever happens to be the default login.
    ///
    /// A profile's binding is effectively permanent — the switcher creates
    /// one directory per account — so these activations are opened once and
    /// left open. There is no reliable way to tell from outside whether a
    /// session is still running, and it does not matter: any turn ever
    /// written under that root belongs to that account whenever it happened.
    public func pollPinnedRoots(_ roots: [URL], now: Date = Date()) {
        for root in roots {
            guard let (url, modified) = observer.currentConfig(
                forRoot: root, homeDirectory: homeDirectory
            ) else { continue }
            let key = url.path
            if let seen = lastModified[key], seen == modified { continue }
            lastModified[key] = modified
            guard let observation = observer.read(
                configAt: url, rootPath: root.standardizedFileURL.path
            ) else { continue }
            record(observation, now: now, source: AccountActivation.sourceExternal,
                   evidence: "session profile \(root.lastPathComponent)")
            applyLabels(from: observation)
        }
    }

    /// Poll the default login's config and record any change.
    ///
    /// Returns the account key currently observed, or nil if it couldn't be
    /// read this cycle.
    ///
    /// **Only the default login for now.** Pinned session profiles
    /// (`CLAUDE_CONFIG_DIR` set to a per-account directory) are not yet
    /// scanned for transcripts — `ClaudePathResolver` resolves roots from
    /// *Pacer's* environment, which never has that variable set, so those
    /// files are outside the scan entirely. That is why attribution can
    /// safely assume "every sample came from the default login" today.
    ///
    /// The moment session roots become scannable, that assumption breaks and
    /// silently misattributes a second account's turns to the first. So the
    /// two changes have to land together: adding a root to the scan requires
    /// carrying its path through `ParsedUsageEntry` into
    /// `AccountTrail.accountId(at:rootPath:)`, which already takes it.
    ///
    /// `credential` is what the keychain token Claude Code bills resolved to.
    /// When it is known and names a different account than the config file,
    /// the file loses: `oauthAccount` is rewritten by every Claude Code
    /// process sharing the root, including ones still holding an identity
    /// from before the last switch, while the credential is the thing on the
    /// wire. See `SignedInCredentialReading`.
    ///
    /// `credentialExpected` says a keychain reading will arrive (the poller is
    /// running) even if none has yet — true for the first cycles after launch.
    /// A disagreeing observation is then held for it instead of accepted,
    /// because a launch is exactly when a stale config is most likely to be
    /// the first thing read.
    @discardableResult
    public func poll(
        now: Date = Date(),
        credential: SignedInCredentialReading? = nil,
        credentialExpected: Bool = false
    ) -> String? {
        needsCredentialCheck = false
        guard let (url, modified) = observer.currentConfig(
            forRoot: nil, homeDirectory: homeDirectory
        ) else { return nil }

        let key = url.path
        if let seen = lastModified[key], seen == modified {
            // Unchanged since last look — whatever we recorded still holds,
            // unless an observation is still waiting on the credential.
            if let pending = pendingObservation {
                decide(pending.observation, fileModified: pending.fileModified,
                       credential: credential, credentialExpected: credentialExpected,
                       now: now, evidence: url.lastPathComponent)
            }
            return trail().currentDefaultLogin?.accountId
        }
        lastModified[key] = modified

        guard let observation = observer.read(configAt: url, rootPath: nil) else {
            return trail().currentDefaultLogin?.accountId
        }
        decide(observation, fileModified: modified, credential: credential,
               credentialExpected: credentialExpected, now: now,
               evidence: url.lastPathComponent)
        applyLabels(from: observation)
        enrichUnlabelledAccounts()
        return trail().currentDefaultLogin?.accountId ?? observation.accountKey
    }

    /// Accept, defer, or reject one config observation of the default login.
    private func decide(
        _ observation: ActiveAccountObserver.Observation,
        fileModified: Date,
        credential: SignedInCredentialReading?,
        credentialExpected: Bool,
        now: Date,
        evidence: String
    ) {
        let observed = observation.accountKey
        let current = trail().currentDefaultLogin?.accountId
        if current == observed {
            pendingObservation = nil
            return
        }
        // A pending sighting of this same account keeps its first-seen time.
        let firstSeen = (pendingObservation?.observation.accountKey == observed)
            ? (pendingObservation?.firstSeen ?? now) : now

        // No keychain read yet, but one is on its way: hold rather than let
        // the first thing read after a launch overwrite a known login.
        guard let credential else {
            if credentialExpected, current != nil {
                hold(observation, firstSeen: firstSeen, fileModified: fileModified,
                     now: now, evidence: evidence)
            } else {
                accept(observation, at: firstSeen, now: now, evidence: evidence)
            }
            return
        }
        // No verdict available from the credential — an unresolved token (a
        // switch in progress, before its first poll), or it agrees. Nothing
        // can veto the file.
        guard let signedIn = credential.accountKey, signedIn != observed else {
            accept(observation, at: firstSeen, now: now, evidence: evidence)
            return
        }
        // The keychain was read after the file was written and still held
        // another account's token: nothing switched. Some other Claude Code
        // process wrote back an identity it was holding.
        if credential.readAt >= fileModified {
            pendingObservation = nil
            // A trail with no open default span would otherwise stay empty and
            // leave every turn unattributed; the credential is itself an
            // observation of who is signed in, so open the span from it.
            if current == nil {
                record(ActiveAccountObserver.Observation(
                           organizationId: signedIn, accountUuid: nil, emailAddress: nil,
                           organizationName: nil, rootPath: nil),
                       now: now, source: AccountActivation.sourceCredential,
                       evidence: "signed-in credential (keychain)")
            }
            if lastRejectedKey != observed {
                lastRejectedKey = observed
                Log.write("AccountTrail",
                          "config names \(observed.prefix(4)) but the signed-in credential is "
                            + "\(signedIn.prefix(4)) — ignoring the stale config write")
            }
            return
        }
        // The credential predates the write, so it cannot tell a real switch
        // from a stale one yet. Hold the observation and ask for a re-read.
        hold(observation, firstSeen: firstSeen, fileModified: fileModified,
             now: now, evidence: evidence)
    }

    private func hold(
        _ observation: ActiveAccountObserver.Observation,
        firstSeen: Date,
        fileModified: Date,
        now: Date,
        evidence: String
    ) {
        pendingObservation = (observation, firstSeen, fileModified)
        if now.timeIntervalSince(firstSeen) >= Self.credentialVerificationTimeout {
            accept(observation, at: firstSeen, now: now, evidence: evidence)
            return
        }
        needsCredentialCheck = true
    }

    private func accept(
        _ observation: ActiveAccountObserver.Observation,
        at start: Date,
        now: Date,
        evidence: String
    ) {
        pendingObservation = nil
        lastRejectedKey = nil
        let previous = trail().currentDefaultLogin?.accountId
        record(observation, now: start, source: AccountActivation.sourceObserved,
               evidence: "oauthAccount in \(evidence)")
        // Accepted late: turns between the sighting and now were stamped with
        // the account being left.
        if start < now, let previous, previous != observation.accountKey {
            corrections.append(Correction(
                from: start, to: nil,
                wrongAccount: previous, rightAccount: observation.accountKey))
        }
    }

    /// Bring the default login's trail in line with the signed-in credential.
    ///
    /// Between `reading.since` and `reading.readAt` every keychain read found
    /// the same account's token, so any default-login span naming a different
    /// account inside that interval is contradicted by what Claude Code was
    /// actually billing. A span that *starts* inside it was opened by a stale
    /// config write and is refuted outright (kept, zero-length, for the
    /// record); one that started earlier is cut off at `since`. Either way the
    /// credential's account takes over the range, and the range is returned
    /// so the caller can re-stamp turns already stored against the wrong one.
    ///
    /// Spans starting after `readAt` are left alone: the keychain has not been
    /// read since, so they may be a real switch not yet confirmed. Manual and
    /// backfilled ranges are the user's statements and are never overridden.
    ///
    /// Cheap on the common cycle: an in-memory probe of the cached trail, and
    /// no store access unless it finds a conflict.
    public func reconcile(with reading: SignedInCredentialReading, now: Date = Date()) {
        guard let signedIn = reading.accountKey else { return }
        guard trail().defaultLoginConflicts(
            with: signedIn, from: reading.since, through: reading.readAt) else { return }

        let descriptor = FetchDescriptor<AccountActivation>(
            predicate: #Predicate { $0.rootPath == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var changed = false
        for row in rows where row.accountId != signedIn {
            guard row.source != AccountActivation.sourceManual,
                  row.source != AccountActivation.sourceBackfill else { continue }
            let end = row.endedAt ?? .distantFuture
            guard end > row.startedAt,
                  row.startedAt <= reading.readAt,
                  end > reading.since else { continue }

            let from = max(row.startedAt, reading.since)
            let to = row.endedAt
            if row.startedAt >= reading.since {
                row.endedAt = row.startedAt
                row.evidence = (row.evidence.map { $0 + " · " } ?? "")
                    + "refuted by the signed-in credential"
            } else {
                row.endedAt = reading.since
            }
            context.insert(AccountActivation(
                accountId: signedIn,
                startedAt: from,
                endedAt: to,
                rootPath: nil,
                source: AccountActivation.sourceCredential,
                evidence: "signed-in credential (keychain)"
            ))
            corrections.append(Correction(
                from: from, to: to, wrongAccount: row.accountId, rightAccount: signedIn))
            changed = true
            Log.write("AccountTrail",
                      "signed-in credential is \(signedIn.prefix(4)), not \(row.accountId.prefix(4)), "
                        + "from \(from) — correcting the trail")
        }
        if changed {
            cachedTrail = nil
            try? context.save()
        }
    }

    /// Move the default login's `[from, to)` from `wrongAccount` to
    /// `rightAccount`, because the user said so.
    ///
    /// The repair for history written before the credential could speak for
    /// itself. A stale config write that predates this fix left turns stamped
    /// with the wrong account, and nothing in the store records which token
    /// the keychain held back then: rate-limit rows carry the account a
    /// response named, not which lane asked, and the poller's own "active"
    /// flag followed the same stale file. So this takes a statement, not an
    /// inference, and records it as `sourceManual` so nothing automatic ever
    /// overrides it afterwards.
    ///
    /// Only rows naming `wrongAccount` are rewritten; a stretch the trail
    /// already gives to anyone else stays as it is. Manual and backfilled
    /// ranges are never rewritten, and pinned profiles are not touched at all
    /// (this is the default login's trail). A row straddling a boundary is
    /// split so the part outside the range keeps its account. The corrections
    /// are returned and also queued for `drainCorrections`.
    @discardableResult
    public func reassign(
        from: Date,
        to: Date,
        wrongAccount: String,
        rightAccount: String,
        evidence: String
    ) -> [Correction] {
        guard from < to, wrongAccount != rightAccount else { return [] }
        let wrong = wrongAccount
        let descriptor = FetchDescriptor<AccountActivation>(
            predicate: #Predicate { $0.rootPath == nil && $0.accountId == wrong },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var made: [Correction] = []
        let note = "reassigned to \(rightAccount.prefix(8)) by the maintainer"
        for row in rows {
            guard row.source != AccountActivation.sourceManual,
                  row.source != AccountActivation.sourceBackfill else { continue }
            let start = row.startedAt
            let originalEnd = row.endedAt
            let end = originalEnd ?? .distantFuture
            guard end > start, start < to, end > from else { continue }

            let overlapStart = max(start, from)
            let overlapEnd = min(end, to)
            if start < from {
                // Keep the head; carry a tail on if the row runs past `to`.
                row.endedAt = from
                if end > to {
                    context.insert(AccountActivation(
                        accountId: row.accountId, startedAt: to, endedAt: originalEnd,
                        rootPath: nil, source: row.source, evidence: row.evidence))
                }
            } else if end > to {
                // Starts inside the range and runs past it: keep only the tail.
                row.startedAt = to
                row.evidence = (row.evidence.map { $0 + " · " } ?? "") + note
            } else {
                // Wholly inside: kept for the record, covering nothing.
                row.endedAt = row.startedAt
                row.evidence = (row.evidence.map { $0 + " · " } ?? "") + note
            }
            context.insert(AccountActivation(
                accountId: rightAccount, startedAt: overlapStart, endedAt: overlapEnd,
                rootPath: nil, source: AccountActivation.sourceManual, evidence: evidence))
            made.append(Correction(
                from: overlapStart, to: overlapEnd,
                wrongAccount: wrongAccount, rightAccount: rightAccount))
        }
        if !made.isEmpty {
            cachedTrail = nil
            try? context.save()
            corrections.append(contentsOf: made)
        }
        return made
    }

    /// Corrections produced since the last call, oldest first.
    public func drainCorrections() -> [Correction] {
        defer { corrections.removeAll() }
        return corrections
    }

    /// Attach the live login's real identity to its `Account` row.
    ///
    /// Claude Code already knows the email and org name of whoever is signed
    /// in, so there is no reason for Pacer to show a UUID-derived placeholder
    /// for the one account it can always name.
    private func applyLabels(from observation: ActiveAccountObserver.Observation) {
        guard let account = account(id: observation.accountKey) else { return }
        var changed = false
        if let email = observation.emailAddress, !email.isEmpty,
           account.emailAddress != email {
            account.emailAddress = email
            changed = true
        }
        if let org = observation.organizationName, !org.isEmpty,
           account.organizationName != org {
            account.organizationName = org
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Borrow labels from an external switcher for accounts we have never
    /// seen logged in — the only accounts whose name Claude Code's own config
    /// cannot supply, because `oauthAccount` describes one account at a time.
    ///
    /// Gated on there being an unlabelled account, so the common case (every
    /// account already named) does one in-memory check and no file read.
    /// A user-chosen `displayName` is never touched.
    private func enrichUnlabelledAccounts() {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let unlabelled = accounts.filter { $0.emailAddress == nil && $0.organizationName == nil }
        // An account can be fully identified and still be waiting for a *name*:
        // everything Pacer observes is email-derived, so the derived
        // placeholder stands until someone chooses something.
        let unnamed = accounts.filter(\.hasDerivedName)
        guard !unlabelled.isEmpty || !unnamed.isEmpty else { return }

        let directory = ExternalAccountDirectory.discover()
        guard !directory.isEmpty else { return }

        var changed = false
        for account in unlabelled {
            guard let entry = directory.entries[account.id] else { continue }
            account.emailAddress = entry.emailAddress
            account.organizationName = entry.organizationName
            changed = true
        }
        // Adopt the switcher's alias as the name — `cswap alias 1 work` is the
        // user saying what this account is called, and having to say it twice
        // is the kind of thing that makes two tools feel like two tools.
        //
        // Only over a *derived* name: a rename typed into Pacer outranks it,
        // for the same reason it outranks the observed email.
        for account in unnamed {
            guard let alias = directory.entries[account.id]?.alias,
                  !alias.isEmpty, account.displayName != alias else { continue }
            account.displayName = alias
            changed = true
        }
        // And the slot, for every account — ordering is not a name and does not
        // wait on one being absent.
        for account in accounts {
            guard let slot = directory.entries[account.id]?.slot,
                  account.switcherSlot != slot else { continue }
            account.switcherSlot = slot
            changed = true
        }
        if changed { try? context.save() }
    }

    private func account(id: String) -> Account? {
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    /// Apply an observation to the trail, opening and closing activations as
    /// needed. Idempotent: re-applying the same account is a no-op.
    public func record(
        _ observation: ActiveAccountObserver.Observation,
        now: Date,
        source: String,
        evidence: String?
    ) {
        let accountKey = observation.accountKey
        let open = openActivations(rootPath: observation.rootPath)

        if let current = open.first(where: { $0.accountId == accountKey }), open.count == 1 {
            _ = current
            return  // Already recorded and unchanged.
        }
        // Close anything open for this root that isn't the observed account.
        for activation in open where activation.accountId != accountKey {
            activation.endedAt = now
        }
        if !open.contains(where: { $0.accountId == accountKey }) {
            context.insert(AccountActivation(
                accountId: accountKey,
                startedAt: now,
                rootPath: observation.rootPath,
                source: source,
                evidence: evidence
            ))
        }
        cachedTrail = nil
    }

    /// The current trail, built once and reused until a write invalidates it.
    public func trail() -> AccountTrail {
        if let cachedTrail { return cachedTrail }
        let descriptor = FetchDescriptor<AccountActivation>(
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        let built = AccountTrail(spans: rows.map {
            AccountTrail.Span(
                accountId: $0.accountId,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt,
                rootPath: $0.rootPath
            )
        })
        cachedTrail = built
        return built
    }

    /// Drop the cached trail — for callers that wrote activations by another
    /// route (a backfill, a manual assignment in Settings).
    public func invalidate() { cachedTrail = nil }

    private func openActivations(rootPath: String?) -> [AccountActivation] {
        let descriptor = FetchDescriptor<AccountActivation>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.filter { $0.rootPath == rootPath }
    }
}
