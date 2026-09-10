import Foundation
import SwiftData

/// One interval during which a given account was the active Claude Code login.
///
/// This is the record that makes per-account **token and cost** attribution
/// possible at all. The rate-limit side never needed it: `OAuthPoller`
/// resolves each token's `anthropic-organization-id` directly, so
/// `RateLimitSample` and friends have carried `accountId` since the
/// multi-account work landed. The transcript side has no such luxury —
/// Claude Code's JSONL lines carry **no account identity** on billable
/// turns (`accountUuid` appears only on `artifact-autoreact-ledger`
/// bookkeeping lines, never on an assistant message), and `~/.claude.json`'s
/// `oauthAccount` describes only whoever is logged in *right now* and is
/// overwritten in place on every switch.
///
/// So the account a turn belongs to is not recoverable from the turn. It has
/// to be recorded as it happens: "account X was live from T1 to T2", written
/// by `ActiveAccountObserver` as it watches the credential. A sample is then
/// attributed by looking up which activation covers its `sampledAt`.
///
/// **This is deliberately tool-agnostic.** It records *that* the active login
/// changed, not who changed it — so it works identically for someone running
/// claude-swap, someone typing `/logout` and `/login`, and someone using a
/// switcher that doesn't exist yet. Tools that can tell us more (friendlier
/// labels, a switch reason) enrich `source`/`evidence`; nothing depends on
/// them being present.
///
/// **Overlap is legal.** Claude Code can run two accounts at once when a
/// session pins `CLAUDE_CONFIG_DIR` to a second profile, so activations are
/// not a partition of the timeline — two may cover the same instant. When
/// that happens the sample's transcript root disambiguates (a pinned profile
/// writes to its own `projects/` directory, which belongs to exactly one
/// account); `rootPath` is what carries that. An activation with a nil
/// `rootPath` is the *default* login — the one a bare `claude` uses.
@Model
public final class AccountActivation {
    /// The account that was active (`Account.id` — the org id, or
    /// `Account.defaultKey` when the server never named one).
    public var accountId: String
    /// When this account became active. For the first activation ever
    /// recorded this is when Pacer *noticed*, not necessarily when the
    /// switch happened — see `source == sourceBackfill`.
    public var startedAt: Date
    /// When it stopped being active; nil means "still active". Exactly one
    /// activation per `rootPath` should be open at a time.
    public var endedAt: Date?
    /// Which Claude Code data root this activation governs, or nil for the
    /// default login (`~/.claude`). A non-nil value pins the activation to
    /// one profile directory, which is how concurrent accounts stay
    /// distinguishable.
    public var rootPath: String?
    /// How we learned about this activation. Not load-bearing for
    /// attribution — it exists so the UI can be honest about provenance and
    /// so a backfilled guess is never mistaken for an observation.
    public var source: String
    /// Free-text corroboration for `source`, shown in diagnostics: the field
    /// we read, the slot number a tool reported, the user's own words when
    /// they assigned a range by hand. Never a secret.
    public var evidence: String?

    #Index<AccountActivation>([\.startedAt], [\.accountId], [\.rootPath])

    public init(
        accountId: String,
        startedAt: Date,
        endedAt: Date? = nil,
        rootPath: String? = nil,
        source: String,
        evidence: String? = nil
    ) {
        self.accountId = accountId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rootPath = rootPath
        self.source = source
        self.evidence = evidence
    }

    /// Pacer watched the credential change for itself. The only source that
    /// is a direct observation rather than an inference.
    public static let sourceObserved = "observed"
    /// An external switcher told us. Carries the tool's own labelling in
    /// `evidence` (e.g. a slot number), but the account id still comes from
    /// the org the token resolves to — never from the tool's say-so.
    public static let sourceExternal = "external"
    /// The user assigned this range by hand.
    public static let sourceManual = "manual"
    /// Inferred for history that predates the trail. Always a guess, always
    /// labelled as one, and never written without the user confirming the
    /// range — history that we cannot attribute stays unattributed rather
    /// than being quietly assigned to whoever is convenient.
    public static let sourceBackfill = "backfill"
}
