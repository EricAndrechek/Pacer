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

    public init(
        context: ModelContext,
        observer: ActiveAccountObserver = ActiveAccountObserver(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.context = context
        self.observer = observer
        self.homeDirectory = homeDirectory
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

    @discardableResult
    public func poll(now: Date = Date()) -> String? {
        guard let (url, modified) = observer.currentConfig(
            forRoot: nil, homeDirectory: homeDirectory
        ) else { return nil }

        let key = url.path
        if let seen = lastModified[key], seen == modified {
            // Unchanged since last look — whatever we recorded still holds.
            return trail().currentDefaultLogin?.accountId
        }
        lastModified[key] = modified

        guard let observation = observer.read(configAt: url, rootPath: nil) else {
            return trail().currentDefaultLogin?.accountId
        }
        record(observation, now: now, source: AccountActivation.sourceObserved,
               evidence: "oauthAccount in \(url.lastPathComponent)")
        applyLabels(from: observation)
        enrichUnlabelledAccounts()
        return observation.accountKey
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
