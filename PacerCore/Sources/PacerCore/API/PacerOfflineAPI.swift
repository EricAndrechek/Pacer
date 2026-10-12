import Foundation
import SwiftData

/// One read route's answer, the same whether the local server sends it or the
/// `pacer` command line computes it in-process.
public struct PacerRouteAnswer: Sendable, Equatable {
    public let status: Int
    public let contentType: String
    public let body: String

    public init(status: Int, contentType: String, body: String) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    static let json = "application/json; charset=utf-8"
    static let text = "text/plain"
    static let prometheus = "text/plain; version=0.0.4; charset=utf-8"
}

/// The reads `pace` makes, answered from the store when nothing is listening
/// on Pacer's port (#194).
///
/// The local API is opt-in, and most people never turn it on, so until now
/// pacing simply stopped there: "API off, proceeding ungated". But the app
/// keeps the store current whether or not it serves it, and the CLI is signed
/// into the same App Group, so it can read what the server would have said.
/// It answers with the server's own builders (`PacerAPISnapshot`,
/// `PacerSessionLookupBuilder`) and the server's own route answers
/// (`metrics`, `session`, `sessions` below), so the two sources agree by
/// construction rather than by test.
///
/// Read-only, always: a second process writing the live store while the app
/// runs is not something to discover later. The snapshot is rebuilt when the
/// one in hand is older than `maximumAge`, which only `wait`'s polling loop
/// ever notices.
public final class PacerOfflineAPI: @unchecked Sendable {

    static let maximumAge: TimeInterval = 2

    private let container: ModelContainer
    private let activeAccountId: () -> String?
    private let desktop: DesktopSessionDirectory?
    private let lock = NSLock()
    private var snapshot: PacerAPISnapshot?

    /// `activeAccountId` is read at each build: it is the App Group mirror in
    /// the CLI, and a login can change while `wait` runs.
    public init(container: ModelContainer,
                activeAccountId: @escaping () -> String? = { UsageScope.storedActiveAccountId },
                desktop: DesktopSessionDirectory? = .shared) {
        self.container = container
        self.activeAccountId = activeAccountId
        self.desktop = desktop
    }

    /// The shared store, opened so that nothing can be saved through it.
    public static func readOnlyContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(url: try PacerStore.storeURL(), allowsSave: false))
    }

    /// The answer for `path` with `query`, or nil for a route this does not
    /// serve offline. nil reads to `pace` exactly as "nothing listening" did.
    public func respond(path: String, query: [String: String], now: Date = Date()) -> PacerRouteAnswer? {
        switch path {
        case "/metrics":
            guard let snapshot = current(now) else { return nil }
            return Self.metrics(snapshot: snapshot, query: query, now: now, version: "offline", build: "")
        case "/v1/session":
            let snapshot = current(now)
            return Self.session(id: query["id"], snapshot: snapshot, now: now) { id in
                try PacerSessionLookupBuilder.lookup(container: self.container, sessionId: id, now: now)
            }
        case "/v1/sessions":
            guard let snapshot = current(now) else { return nil }
            return Self.sessions(query: query, resolve: snapshot.resolve) { within, account in
                try PacerSessionLookupBuilder.list(container: self.container, withinSeconds: within,
                                                   account: account, now: now, desktop: self.desktop)
            }
        default:
            return nil
        }
    }

    private func current(_ now: Date) -> PacerAPISnapshot? {
        lock.withLock {
            if let snapshot, now.timeIntervalSince(snapshot.builtAt) < Self.maximumAge { return snapshot }
            snapshot = try? PacerAPISnapshot.build(container: container, activeAccountId: activeAccountId(),
                                                   desktop: desktop, now: now)
            return snapshot
        }
    }

    // MARK: - Route answers, shared with the local server

    /// `/metrics`. A scrape passes neither `?account=` nor `?config_dir=` and
    /// gets every account; a client passes one and gets its own login's.
    public static func metrics(snapshot: PacerAPISnapshot, query: [String: String], now: Date,
                               version: String, build: String) -> PacerRouteAnswer {
        let wanted: String?
        switch snapshot.resolve(query) {
        case .rejected(let message):
            return PacerRouteAnswer(status: 400, contentType: PacerRouteAnswer.text, body: message)
        case .all: wanted = nil
        case .scoped(let key): wanted = key
        }
        let text = snapshot.metrics(account: wanted, now: now, version: version, build: build).prometheusText()
        return PacerRouteAnswer(status: 200, contentType: PacerRouteAnswer.prometheus, body: text)
    }

    /// `/v1/session?id=`: from the snapshot when it has the session (#211),
    /// else from `lookup`. nil from the snapshot step means "ask the store",
    /// which the server does on its store queue and the CLI inline.
    public static func session(id: String?, snapshot: PacerAPISnapshot?, now: Date,
                               lookup: (String) throws -> PacerSessionLookup?) -> PacerRouteAnswer {
        guard let id, !id.isEmpty else {
            return PacerRouteAnswer(status: 400, contentType: PacerRouteAnswer.text,
                                    body: "Pass ?id=<session id> (Claude Code sets CLAUDE_CODE_SESSION_ID)\n")
        }
        if let answer = sessionFromSnapshot(id: id, snapshot: snapshot, now: now) { return answer }
        guard let session = (try? lookup(id)) ?? nil, let json = try? session.encodedJSON() else {
            // Not an error: a session Pacer has not yet parsed a turn from is
            // a real state, and one a caller falls back from rather than
            // retries.
            return PacerRouteAnswer(status: 404, contentType: PacerRouteAnswer.text,
                                    body: "No turns recorded for that session yet\n")
        }
        return PacerRouteAnswer(status: 200, contentType: PacerRouteAnswer.json, body: json)
    }

    /// The snapshot half of `session`, for the server's fast path.
    public static func sessionFromSnapshot(id: String, snapshot: PacerAPISnapshot?,
                                           now: Date) -> PacerRouteAnswer? {
        guard let snapshot, let session = snapshot.session(id: id, at: now),
              let json = try? session.encodedJSON() else { return nil }
        return PacerRouteAnswer(status: 200, contentType: PacerRouteAnswer.json, body: json)
    }

    /// `/v1/sessions?within=&account=`.
    public static func sessions(query: [String: String],
                                resolve: ([String: String]) -> PacerAccountQuery,
                                list: (TimeInterval, String?) throws -> PacerSessionList) -> PacerRouteAnswer {
        let within = query["within"].flatMap { Double($0) } ?? LiveSessionActivity.recentThreshold
        let account: String?
        switch resolve(query) {
        case .rejected(let message):
            return PacerRouteAnswer(status: 400, contentType: PacerRouteAnswer.text, body: message)
        case .all: account = nil
        case .scoped(let key): account = key
        }
        guard let sessions = try? list(within, account), let json = try? sessions.encodedJSON() else {
            return PacerRouteAnswer(status: 503, contentType: PacerRouteAnswer.text, body: "No data yet\n")
        }
        return PacerRouteAnswer(status: 200, contentType: PacerRouteAnswer.json, body: json)
    }
}
