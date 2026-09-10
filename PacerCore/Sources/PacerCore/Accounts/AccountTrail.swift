import Foundation

/// An immutable, queryable snapshot of the `AccountActivation` timeline.
///
/// Attribution runs inside the scan's insert loop, once per sample, on a path
/// that already has a per-cycle budget measured in tens of milliseconds. So
/// this is built once per cycle from a table that holds a handful of rows and
/// answers each lookup with a binary search rather than a fetch.
///
/// The lookup is deliberately conservative: when the trail cannot say which
/// account a sample belongs to, it returns nil and the sample stays
/// unattributed. Guessing here would produce a wrong cost split that reads as
/// authoritative, which is the same failure shape as a missing price
/// rendering as `$0` — a number nothing ever revisits because nothing looks
/// wrong. Unattributed is visibly incomplete; misattributed is invisibly
/// false.
public struct AccountTrail: Sendable {
    /// One activation, flattened to a value type so the trail can cross
    /// actor boundaries without dragging a `ModelContext` along.
    public struct Span: Sendable, Equatable {
        public let accountId: String
        public let startedAt: Date
        public let endedAt: Date?
        public let rootPath: String?

        public init(accountId: String, startedAt: Date, endedAt: Date?, rootPath: String?) {
            self.accountId = accountId
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.rootPath = rootPath
        }

        func covers(_ instant: Date) -> Bool {
            guard instant >= startedAt else { return false }
            guard let endedAt else { return true }
            return instant < endedAt
        }
    }

    /// Spans governing a pinned profile directory, grouped by that path.
    private let pinned: [String: [Span]]
    /// Spans governing the default login, sorted by `startedAt`.
    private let defaultLogin: [Span]

    public static let empty = AccountTrail(spans: [])

    public init(spans: [Span]) {
        var pinned: [String: [Span]] = [:]
        var defaultLogin: [Span] = []
        for span in spans {
            if let root = span.rootPath {
                pinned[root, default: []].append(span)
            } else {
                defaultLogin.append(span)
            }
        }
        self.pinned = pinned.mapValues { $0.sorted { $0.startedAt < $1.startedAt } }
        self.defaultLogin = defaultLogin.sorted { $0.startedAt < $1.startedAt }
    }

    public var isEmpty: Bool { pinned.isEmpty && defaultLogin.isEmpty }

    /// The account a sample belongs to, or nil when the trail can't say.
    ///
    /// `rootPath` is the Claude Code data root the sample's transcript was
    /// found under. A root that some activation has claimed is decisive — a
    /// pinned profile belongs to exactly one account, which is what makes
    /// two accounts running at the same time separable. Any other root is
    /// the default login, answered from the default-login spans.
    ///
    /// A pinned root deliberately does **not** fall back to the default
    /// login when its own spans don't cover the instant: those transcripts
    /// are known not to be the default account's, so "unknown" is the honest
    /// answer and the default login's id would be a wrong one.
    public func accountId(at instant: Date, rootPath: String? = nil) -> String? {
        if let rootPath, let spans = pinned[rootPath] {
            return Self.lookup(instant, in: spans)
        }
        return Self.lookup(instant, in: defaultLogin)
    }

    /// The most recent span for the default login, if any is still open.
    public var currentDefaultLogin: Span? {
        defaultLogin.last { $0.endedAt == nil }
    }

    /// Every distinct account the trail has ever seen active.
    public var accountIds: Set<String> {
        var ids = Set(defaultLogin.map(\.accountId))
        for spans in pinned.values { ids.formUnion(spans.map(\.accountId)) }
        return ids
    }

    /// Whether two accounts were ever active at the same instant — the
    /// signal that distinguishes someone running accounts in *parallel*
    /// from someone *switching* between them. The presentation layer adapts
    /// on this rather than on a user-set mode, so a person who starts
    /// running parallel sessions gets the richer views without configuring
    /// anything, and their existing history stays correct across the change.
    public var hasConcurrentAccounts: Bool {
        var all = defaultLogin
        for spans in pinned.values { all.append(contentsOf: spans) }
        guard all.count > 1 else { return false }
        all.sort { $0.startedAt < $1.startedAt }
        for i in all.indices.dropLast() {
            guard let end = all[i].endedAt else {
                // An open span overlaps anything that starts after it.
                if all[(i + 1)...].contains(where: { $0.accountId != all[i].accountId }) {
                    return true
                }
                continue
            }
            for later in all[(i + 1)...] {
                if later.startedAt >= end { break }
                if later.accountId != all[i].accountId { return true }
            }
        }
        return false
    }

    /// Binary search for the last span starting at or before `instant`,
    /// then walk back over any spans that don't cover it. The walk is
    /// bounded in practice (spans for one root rarely overlap) and keeps
    /// the answer correct if they ever do.
    private static func lookup(_ instant: Date, in spans: [Span]) -> String? {
        guard !spans.isEmpty else { return nil }
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].startedAt <= instant { low = mid + 1 } else { high = mid }
        }
        var i = low - 1
        while i >= 0 {
            if spans[i].covers(instant) { return spans[i].accountId }
            i -= 1
        }
        return nil
    }
}
