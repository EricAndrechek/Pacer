import Foundation
import Network
import PacerCore

extension Notification.Name {
    /// Posted by the Settings UI when any API-server preference changes, so
    /// `AppBackgroundService` can re-apply the config (stop/start the listener).
    static let pacerAPIServerSettingsChanged = Notification.Name("PacerAPIServerSettingsChanged")

    /// Posted when a request asks for one account's snapshot, with that
    /// account's id in `userInfo["accountId"]`.
    ///
    /// A per-account payload's forecast fields come from that account's engine
    /// scope, and a scope nothing has asked for in fifteen minutes stops being
    /// refitted (`EngineHost.live`) — so without this a scripted consumer would
    /// get live percentages and permanently empty projections unless a human
    /// happened to have the dashboard scoped to the same account. Asking is the
    /// same thing the dashboard's scope switcher does, and the idle grace
    /// applies identically: stop polling and the scope goes cold on its own.
    static let pacerAPIDidRequestAccountScope = Notification.Name("PacerAPIDidRequestAccountScope")
}

/// Observable status for the Settings card. The server calls `set` from its
/// background queue; we marshal the `@Published` mutation onto the main thread
/// ourselves, so the type stays freely accessible (not main-actor-isolated)
/// from the SwiftUI view's property initializer.
final class PacerAPIServerStatus: ObservableObject, @unchecked Sendable {
    static let shared = PacerAPIServerStatus()
    @Published var text: String = "Stopped"
    @Published var isError: Bool = false
    private init() {}

    func set(_ text: String, isError: Bool) {
        if Thread.isMainThread {
            self.text = text
            self.isError = isError
        } else {
            DispatchQueue.main.async {
                self.text = text
                self.isError = isError
            }
        }
    }
}

/// Opt-in local HTTP server exposing Pacer's usage data to anything on the
/// machine (or LAN, if the user widens the bind address): a Stream Deck
/// plugin, a Prometheus scraper like Grafana Alloy, a shell `curl`, etc.
///
/// Endpoints (all `GET`):
/// - `/v1/snapshot` — the full `PacerSnapshotPayload` as JSON. `?account=`
///                    scopes every number in it to one login; without it,
///                    cost and tokens cover every account and the limits
///                    are the active login's.
/// - `/v1/accounts`  — the accounts Pacer tracks, and the ids `?account=` takes.
/// - `/v1/limits/history` — every window's utilization over time, bucketed
///                    (`?hours=`, `?bucket=15m`).
/// - `/v1/session`   — what Pacer knows about one session (`?id=`): the model
///                    it is running and the account its work is billed to, so
///                    a script inside a session can stop guessing about
///                    itself.
/// - `/metrics`     — Prometheus text exposition (0.0.4). Also takes
///                    `?account=` / `?config_dir=` so a *client* can ask for
///                    one login; a scrape sends neither and gets them all.
/// - `/v1/stream`   — Server-Sent Events; a `snapshot` event on connect and on
///                    every engine recompute, plus `:keepalive` comments.
/// - `/healthz`     — liveness (unauthenticated).
/// - `/`            — JSON service info (unauthenticated).
///
/// Built directly on `Network.framework` (`NWListener`) — no third-party HTTP
/// dependency in a notarized app. The app is not sandboxed, so binding a
/// listening socket needs no extra entitlement.
///
/// **Answers come from memory (#191).** `/metrics`, `/v1/snapshot` and
/// `/v1/accounts` render a `PacerAPISnapshot` that `PacerAPISnapshotRefresher`
/// rebuilds in the background, with every seconds-from-now field rebased to
/// the moment of the request. A store that has slowed to tens of seconds per
/// read makes those answers stale — by an age every answer carries — instead
/// of making the whole API stop answering, which is what it did on 2026-10-07
/// and why every session's pacing gate failed open that night.
///
/// Concurrency: `@unchecked Sendable`, with the state split three ways.
/// - **`queue` (serial)** owns the listener, every connection's lifecycle,
///   `sseClients`, `config` and the keepalive timer. It parses request heads,
///   hands them on and writes to stream subscribers, nothing slower, so it is
///   never busy for long; `/healthz` and `/` are answered right there,
///   touching nothing that can block.
/// - **`workQueue` (concurrent)** runs every other route, so no request waits
///   behind another. The token is captured on `queue` when the work is
///   handed over, so routes never read `config`.
/// - **`storeQueue`** runs the endpoints that still read the store
///   (`/v1/session`, `/v1/sessions`, `/v1/limits/history`, `/v1/usage/*`,
///   `/v1/predictions/history`), a few at a time — see its doc comment.
///
/// What routes share is lock-protected: the snapshot cache, the refresher's
/// state and `scopeAnnouncedAt`. `NWConnection.send` is safe from any thread;
/// its completions arrive on `queue`. `ClientConnection` is the only thing
/// that crosses the `Network.framework` `@Sendable` callback boundary, and
/// it's a wrapper we own.
final class PacerHTTPServer: @unchecked Sendable {

    struct Config: Sendable, Equatable {
        let host: String
        let port: UInt16
        let token: String?
    }

    private final class ClientConnection: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var isSSE = false
        init(_ connection: NWConnection) { self.connection = connection }
        var id: ObjectIdentifier { ObjectIdentifier(self) }
    }

    private let queue = DispatchQueue(label: "com.ericandrechek.pacer.http")
    private let workQueue = DispatchQueue(label: "com.ericandrechek.pacer.http.work",
                                          qos: .userInitiated, attributes: .concurrent)
    /// The store-reading endpoints, at most `storeConcurrency` at once.
    ///
    /// Bounded because a store stall is exactly when these pile up: a GCD
    /// worker blocked on a read is a thread held for the length of the stall,
    /// and enough of them exhaust the process's pool — taking the cached
    /// endpoints, and everything else in the app that uses GCD, down with
    /// them. Queued operations hold no thread.
    private let storeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.ericandrechek.pacer.http.store"
        queue.maxConcurrentOperationCount = PacerHTTPServer.storeConcurrency
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var listener: NWListener?
    private var sseClients: [ObjectIdentifier: ClientConnection] = [:]
    private var keepalive: DispatchSourceTimer?
    private var config: Config?

    private let snapshots = PacerAPISnapshotCache()
    private let refresher: PacerAPISnapshotRefresher

    /// Last time each account scope was announced, so a tight scrape loop
    /// posts once a minute rather than once a request. `EngineHost`'s grace
    /// period is fifteen minutes, so this is far more often than it needs.
    /// Guarded by `scopeLock`: routes run concurrently.
    private var scopeAnnouncedAt: [String: Date] = [:]
    private let scopeLock = NSLock()

    private let appVersion: String
    private let appBuild: String

    static let storeConcurrency = 4
    /// How long a cached endpoint waits for the first snapshot on a cold
    /// start before answering 503. Under `pace.sh`'s 5 s client timeout, so
    /// the client hears the 503 rather than giving up first.
    private static let firstSnapshotWait: TimeInterval = 3
    /// A store read that waited this long for a slot is answered 503 without
    /// running: its client has almost certainly given up (`pace.sh` waits
    /// 5 s), and doing the read anyway is how a backlog never drains.
    private static let storeQueueShedAfter: TimeInterval = 10
    private static let retryAfterSeconds = 5

    init() {
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        refresher = PacerAPISnapshotRefresher(cache: snapshots)
    }

    // MARK: - Lifecycle (callable from any actor)

    func start(config: Config) {
        queue.async { [weak self] in self?.startLocked(config) }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked(status: "Stopped", isError: false) }
    }

    private func startLocked(_ cfg: Config) {
        stopLocked(status: nil, isError: false)
        config = cfg
        guard let port = NWEndpoint.Port(rawValue: cfg.port) else {
            publish("Invalid port \(cfg.port)", isError: true)
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener: NWListener
            if cfg.host == "0.0.0.0" {
                newListener = try NWListener(using: params, on: port)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(cfg.host), port: port)
                newListener = try NWListener(using: params)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async { self.handleListenerState(state, cfg: cfg) }
            }
            newListener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.queue.async { self.accept(conn) }
            }
            listener = newListener
            newListener.start(queue: queue)
            refresher.start { [weak self] snapshot in self?.broadcast(snapshot) }
            startKeepalive()
        } catch {
            publish("Failed to start: \(error.localizedDescription)", isError: true)
            Log.write("HTTPServer", "start failed: \(error)")
        }
    }

    private func stopLocked(status: String?, isError: Bool) {
        listener?.cancel()
        listener = nil
        for client in sseClients.values { client.connection.cancel() }
        sseClients.removeAll()
        keepalive?.cancel()
        keepalive = nil
        refresher.stop()
        scopeLock.withLock { scopeAnnouncedAt.removeAll() }
        if let status { publish(status, isError: isError) }
    }

    private func handleListenerState(_ state: NWListener.State, cfg: Config) {
        switch state {
        case .ready:
            publish("Listening on http://\(cfg.host):\(cfg.port)", isError: false)
            Log.write("HTTPServer", "listening on \(cfg.host):\(cfg.port)")
        case .failed(let error):
            // Most common: port already in use (EADDRINUSE).
            publish("Failed: \(error.localizedDescription)", isError: true)
            Log.write("HTTPServer", "listener failed: \(error)")
            stopLocked(status: nil, isError: true)
        case .waiting(let error):
            publish("Waiting: \(error.localizedDescription)", isError: true)
        default:
            break
        }
    }

    // MARK: - Connection handling (all on `queue`)

    private func accept(_ conn: NWConnection) {
        let client = ClientConnection(conn)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                guard let self else { return }
                self.queue.async { self.sseClients[client.id] = nil }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: ClientConnection) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.buffer.append(data)
                if client.buffer.count > 64 * 1024 {
                    self.respond(client, status: 431, contentType: "text/plain", body: Data("Request header too large\n".utf8))
                    return
                }
                if let terminator = client.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = client.buffer.subdata(in: client.buffer.startIndex..<terminator.lowerBound)
                    self.handleRequest(head, client: client)
                    return
                }
            }
            if isComplete || error != nil {
                client.connection.cancel()
                self.sseClients[client.id] = nil
                return
            }
            self.receive(client)
        }
    }

    private func handleRequest(_ head: Data, client: ClientConnection) {
        guard let text = String(data: head, encoding: .utf8) else {
            respond(client, status: 400, contentType: "text/plain", body: Data("Bad Request\n".utf8))
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(client, status: 400, contentType: "text/plain", body: Data("Bad Request\n".utf8))
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let pathQuery = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pathQuery.first.map(String.init) ?? rawPath
        let query = Self.parseQuery(pathQuery.count > 1 ? String(pathQuery[1]) : "")

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        guard method == "GET" else {
            respond(client, status: 405, contentType: "text/plain", body: Data("Method Not Allowed\n".utf8))
            return
        }
        switch path {
        // Answered here, on the listener's queue, touching nothing: no lock,
        // no snapshot, no store, no worker thread. Liveness has to stay
        // true-or-absent about the process alone, not about the store.
        case "/healthz":
            respond(client, status: 200, contentType: "text/plain", body: Data("ok\n".utf8))
        case "/":
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: infoJSON())
        default:
            let token = config?.token
            workQueue.async { [self, headers] in
                route(path: path, query: query, headers: headers, token: token, client: client)
            }
        }
    }

    /// Every route but the two above, on `workQueue`.
    private func route(path: String, query: [String: String], headers: [String: String],
                       token: String?, client: ClientConnection) {
        switch path {
        case "/v1/snapshot":
            guard Self.authorized(headers, token: token) else { return unauthorized(client) }
            guard let snapshot = readySnapshot() else {
                return notReady(client, body: "No data yet\n")
            }
            let snapshotAccount: String?
            switch snapshot.resolve(query) {
            case .rejected(let message):
                return respond(client, status: 400, contentType: "text/plain", body: Data(message.utf8))
            case .all: snapshotAccount = nil
            case .scoped(let key):
                snapshotAccount = key
                announceAccountScope(key)
            }
            let now = Date()
            guard let json = try? snapshot.payload(account: snapshotAccount, at: now)?.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8",
                    body: Data(json.utf8), extraHeaders: Self.ageHeader(snapshot, now: now))
        case "/v1/accounts":
            guard Self.authorized(headers, token: token) else { return unauthorized(client) }
            guard let snapshot = readySnapshot() else {
                return notReady(client, body: "No data yet\n")
            }
            let now = Date()
            guard let json = try? snapshot.accountList(at: now).encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8",
                    body: Data(json.utf8), extraHeaders: Self.ageHeader(snapshot, now: now))
        case "/metrics":
            guard Self.authorized(headers, token: token) else { return unauthorized(client) }
            guard let snapshot = readySnapshot() else {
                return notReady(client, body: "# no data yet\n")
            }
            // A scrape passes neither parameter and gets every account, which
            // is what a time-series database wants. A *client* — the pacing
            // skill, in a session pinned to one profile — passes one and gets
            // only its own login's windows, without having to know that
            // account's id.
            let wanted: String?
            switch snapshot.resolve(query) {
            case .rejected(let message):
                return respond(client, status: 400, contentType: "text/plain", body: Data(message.utf8))
            case .all: wanted = nil
            case .scoped(let key): wanted = key
            }
            let now = Date()
            let text = snapshot.metrics(account: wanted, now: now,
                                        version: appVersion, build: appBuild).prometheusText()
            respond(client, status: 200, contentType: "text/plain; version=0.0.4; charset=utf-8",
                    body: Data(text.utf8), extraHeaders: Self.ageHeader(snapshot, now: now))
        case "/v1/stream":
            guard Self.authorized(headers, token: token) else { return unauthorized(client) }
            queue.async { [self] in startSSE(client) }
        case "/v1/usage/daily", "/v1/usage/models", "/v1/sessions", "/v1/session",
             "/v1/limits/history", "/v1/predictions/history":
            guard Self.authorized(headers, token: token) else { return unauthorized(client) }
            let enqueuedAt = Date()
            storeQueue.addOperation { [self] in
                guard Date().timeIntervalSince(enqueuedAt) < Self.storeQueueShedAfter else {
                    return respond(client, status: 503, contentType: "text/plain",
                                   body: Data("Busy, try again\n".utf8),
                                   extraHeaders: ["Retry-After": "\(Self.retryAfterSeconds)"])
                }
                storeRoute(path: path, query: query, client: client)
            }
        default:
            respond(client, status: 404, contentType: "text/plain", body: Data("Not Found\n".utf8))
        }
    }

    /// The endpoints that still read the store, on `storeQueue`. Unchanged
    /// from when every route ran inline, except that account resolution now
    /// comes from the snapshot when there is one.
    private func storeRoute(path: String, query: [String: String], client: ClientConnection) {
        switch path {
        case "/v1/usage/daily":
            let days = query["days"].flatMap { Int($0) } ?? 30
            let account: String?
            switch resolveAccount(query) {
            case .rejected(let message):
                return respond(client, status: 400, contentType: "text/plain", body: Data(message.utf8))
            case .all: account = nil
            case .scoped(let key): account = key
            }
            guard let usage = try? PacerUsageBuilder.daily(days: days, account: account),
                  let json = try? usage.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        case "/v1/usage/models":
            let account: String?
            switch resolveAccount(query) {
            case .rejected(let message):
                return respond(client, status: 400, contentType: "text/plain", body: Data(message.utf8))
            case .all: account = nil
            case .scoped(let key): account = key
            }
            guard let usage = try? PacerUsageBuilder.models(account: account),
                  let json = try? usage.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        case "/v1/sessions":
            let within = query["within"].flatMap { Double($0) } ?? LiveSessionActivity.recentThreshold
            let sessionAccount: String?
            switch resolveAccount(query) {
            case .rejected(let message):
                return respond(client, status: 400, contentType: "text/plain", body: Data(message.utf8))
            case .all: sessionAccount = nil
            case .scoped(let key): sessionAccount = key
            }
            guard let sessions = try? PacerSessionLookupBuilder.list(
                    withinSeconds: within, account: sessionAccount),
                  let json = try? sessions.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        case "/v1/session":
            guard let id = query["id"], !id.isEmpty else {
                return respond(client, status: 400, contentType: "text/plain",
                               body: Data("Pass ?id=<session id> (Claude Code sets CLAUDE_CODE_SESSION_ID)\n".utf8))
            }
            guard let session = (try? PacerSessionLookupBuilder.lookup(sessionId: id)) ?? nil,
                  let json = try? session.encodedJSON() else {
                // Not an error: a session Pacer has not yet parsed a turn from
                // is a real state, and one a caller falls back from rather than
                // retries.
                return respond(client, status: 404, contentType: "text/plain",
                               body: Data("No turns recorded for that session yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        case "/v1/limits/history":
            let hours = query["hours"].flatMap { Int($0) } ?? 24
            let historyAccount: String?
            switch resolveAccount(query) {
            case .rejected(let message):
                return respond(client, status: 400, contentType: "text/plain", body: Data(message.utf8))
            case .all: historyAccount = nil
            case .scoped(let key): historyAccount = key
            }
            guard let history = try? PacerLimitHistoryBuilder.history(
                    hours: hours,
                    bucketSeconds: PacerLimitHistoryBuilder.parseBucket(query["bucket"]),
                    account: historyAccount),
                  let json = try? history.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        case "/v1/predictions/history":
            let days = query["days"].flatMap { Int($0) } ?? 7
            let surface = query["surface"]
            guard let history = try? PacerPredictionHistoryBuilder.history(days: days, surface: surface),
                  let json = try? history.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        default:
            respond(client, status: 404, contentType: "text/plain", body: Data("Not Found\n".utf8))
        }
    }

    // MARK: - Snapshot

    /// The snapshot to answer from. On a cold start there is none until the
    /// first build lands, so wait for it briefly — on a worker, never on
    /// `queue`, which is what keeps `/healthz` answering meanwhile.
    private func readySnapshot() -> PacerAPISnapshot? {
        snapshots.current ?? snapshots.current(waitingUpTo: Self.firstSnapshotWait)
    }

    private func notReady(_ client: ClientConnection, body: String) {
        respond(client, status: 503, contentType: "text/plain", body: Data(body.utf8),
                extraHeaders: ["Retry-After": "\(Self.retryAfterSeconds)"])
    }

    /// HTTP's own word for "this came from a cache, this many seconds ago".
    /// The body cannot carry it without changing every payload's format, and
    /// `generatedAt` is the instant the countdowns are measured from.
    private static func ageHeader(_ snapshot: PacerAPISnapshot, now: Date) -> [String: String] {
        ["Age": "\(snapshot.ageSeconds(at: now))"]
    }

    /// Resolve `?account=` / `?config_dir=` for the store-reading endpoints:
    /// from the snapshot's account list when there is one, so even these do
    /// not spend a store read on it; from the store before the first build.
    /// See `PacerAccountQuery` for the semantics.
    private func resolveAccount(_ query: [String: String]) -> PacerAccountQuery {
        snapshots.current?.resolve(query) ?? PacerAccountQuery.resolveFromStore(query)
    }

    /// Tell the app an account's numbers are being read, so its engine scope
    /// keeps getting refitted and the next request has projections in it. Rate
    /// limited per account; see `pacerAPIDidRequestAccountScope`.
    private func announceAccountScope(_ accountId: String) {
        // The unattributed bucket is a rollup key for turns that predate the
        // activation trail, not a login: it has no windows and no history to
        // fit, so warming an engine for it would buy a refit per cycle for
        // nothing.
        guard accountId != AccountDailyAggregate.unattributedKey else { return }
        let now = Date()
        let due: Bool = scopeLock.withLock {
            if let last = scopeAnnouncedAt[accountId], now.timeIntervalSince(last) < 60 { return false }
            scopeAnnouncedAt[accountId] = now
            return true
        }
        guard due else { return }
        NotificationCenter.default.post(name: .pacerAPIDidRequestAccountScope, object: nil,
                                        userInfo: ["accountId": accountId])
    }

    /// Parse a URL query string (`a=1&b=2`) into a dict, percent-decoding values.
    private static func parseQuery(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0])
            guard !key.isEmpty else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            out[key] = value.removingPercentEncoding ?? value
        }
        return out
    }

    // MARK: - Auth

    /// `token` is `config`'s, captured on `queue` when the request was handed
    /// to a worker: `config` itself is only ever read there.
    private static func authorized(_ headers: [String: String], token: String?) -> Bool {
        guard let token else { return true }
        guard let header = headers["authorization"] else { return false }
        let expected = "Bearer \(token)"
        return constantTimeEqual(header, expected)
    }

    private func unauthorized(_ client: ClientConnection) {
        respond(client, status: 401, contentType: "text/plain",
                body: Data("Unauthorized\n".utf8),
                extraHeaders: ["WWW-Authenticate": "Bearer"])
    }

    /// Length-independent-leaking compare so a wrong token can't be guessed by
    /// timing. (Overkill on loopback, cheap insurance on `0.0.0.0`.)
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: - SSE (all on `queue`)

    private func startSSE(_ client: ClientConnection) {
        client.isSSE = true
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "\r\n"
        client.connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil { client.connection.cancel(); return }
                self.sseClients[client.id] = client
                // Read at registration, on the queue broadcasts are written
                // from: a snapshot that landed before this is sent here, and
                // one that lands after reaches this client through
                // `broadcast`. Read earlier, a build finishing in between
                // would reach neither. No snapshot yet is fine — the
                // refresher pushes its first build.
                if let json = try? self.snapshots.current?.payload(account: nil, at: Date())?.encodedJSON() {
                    self.writeEvent(client, event: "snapshot", json: json)
                }
            }
        })
    }

    /// Push a snapshot to every subscriber. Called on the refresher's queue;
    /// the encode happens there, and only the writes hop to `queue`.
    private func broadcast(_ snapshot: PacerAPISnapshot) {
        guard let json = try? snapshot.payload(account: nil, at: Date())?.encodedJSON() else { return }
        queue.async { [self] in
            for client in sseClients.values { writeEvent(client, event: "snapshot", json: json) }
        }
    }

    private func writeEvent(_ client: ClientConnection, event: String, json: String) {
        var frame = "event: \(event)\n"
        // SSE requires one `data:` line per physical line of the payload.
        for line in json.split(separator: "\n", omittingEmptySubsequences: false) {
            frame += "data: \(line)\n"
        }
        frame += "\n"
        send(client, Data(frame.utf8), closeAfter: false)
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for client in self.sseClients.values {
                self.send(client, Data(": keepalive\n\n".utf8), closeAfter: false)
            }
        }
        timer.resume()
        keepalive = timer
    }

    // MARK: - Response writing

    private func respond(_ client: ClientConnection, status: Int, contentType: String,
                         body: Data, extraHeaders: [String: String] = [:]) {
        var header = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        for (key, value) in extraHeaders { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        send(client, data, closeAfter: true)
    }

    private func send(_ client: ClientConnection, _ data: Data, closeAfter: Bool) {
        client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || closeAfter {
                client.connection.cancel()
                self.queue.async { self.sseClients[client.id] = nil }
            }
        })
    }

    private func infoJSON() -> Data {
        let info: [String: Any] = [
            "name": "Pacer",
            "version": appVersion,
            "build": appBuild,
            "schemaVersion": 1,
            "endpoints": ["/v1/snapshot", "/v1/accounts", "/v1/session", "/v1/sessions", "/v1/limits/history", "/v1/usage/daily", "/v1/usage/models", "/v1/predictions/history", "/v1/stream", "/metrics", "/healthz"],
        ]
        return (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }

    private func publish(_ text: String, isError: Bool) {
        PacerAPIServerStatus.shared.set(text, isError: isError)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default:  return "Error"
        }
    }
}
