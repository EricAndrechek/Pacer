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
        return observation.accountKey
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
