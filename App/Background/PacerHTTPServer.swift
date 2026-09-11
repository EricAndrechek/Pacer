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
/// Concurrency: `@unchecked Sendable` with a single serial `queue`. Every piece
/// of mutable state (the listener, the SSE client set, the payload cache) is
/// touched only on `queue`; `start`/`stop` are safe to call from the main actor
/// and simply hop onto it. `ClientConnection` is the only thing that crosses
/// the `Network.framework` `@Sendable` callback boundary, and it's a wrapper we
/// own.
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
    private var listener: NWListener?
    private var sseClients: [ObjectIdentifier: ClientConnection] = [:]
    /// Request-driven payload cache, keyed by `?account=` (`""` for the
    /// unscoped one). Bounded by the number of accounts, since every key
    /// has already been validated against the `Account` table.
    private var cached: [String: (payload: PacerSnapshotPayload, at: Date)] = [:]
    private var keepalive: DispatchSourceTimer?
    private var recomputeObserver: NSObjectProtocol?
    private var config: Config?
    /// Last time each account scope was announced, so a tight scrape loop
    /// posts once a minute rather than once a request. `EngineHost`'s grace
    /// period is fifteen minutes, so this is far more often than it needs.
    private var scopeAnnouncedAt: [String: Date] = [:]

    private let appVersion: String
    private let appBuild: String

    /// Cache TTL for request-driven reads (`/v1/snapshot`, `/metrics`). Bounds
    /// the cost of a tight scrape interval; SSE pushes bypass it.
    private static let cacheTTL: TimeInterval = 1.5

    init() {
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
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
            installRecomputeObserver()
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
        if let obs = recomputeObserver {
            NotificationCenter.default.removeObserver(obs)
            recomputeObserver = nil
        }
        cached.removeAll()
        scopeAnnouncedAt.removeAll()
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
        route(path: path, query: query, headers: headers, client: client)
    }

    private func route(path: String, query: [String: String], headers: [String: String], client: ClientConnection) {
        switch path {
        case "/healthz":
            respond(client, status: 200, contentType: "text/plain", body: Data("ok\n".utf8))
        case "/":
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: infoJSON())
        case "/v1/snapshot":
            guard authorized(headers) else { return unauthorized(client) }
            let snapshotAccount: String?
            switch resolveAccount(query) {
            case .rejected(let message):
                return respond(client, status: 400, contentType: "text/plain", body: Data(message.utf8))
            case .all: snapshotAccount = nil
            case .scoped(let key):
                snapshotAccount = key
                announceAccountScope(key)
            }
            guard let payload = currentPayload(account: snapshotAccount),
                  let json = try? payload.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        case "/v1/accounts":
            guard authorized(headers) else { return unauthorized(client) }
            guard let list = try? PacerAccountsBuilder.list(), let json = try? list.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        case "/v1/usage/daily":
            guard authorized(headers) else { return unauthorized(client) }
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
            guard authorized(headers) else { return unauthorized(client) }
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
            guard authorized(headers) else { return unauthorized(client) }
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
            guard authorized(headers) else { return unauthorized(client) }
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
            guard authorized(headers) else { return unauthorized(client) }
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
            guard authorized(headers) else { return unauthorized(client) }
            let days = query["days"].flatMap { Int($0) } ?? 7
            let surface = query["surface"]
            guard let history = try? PacerPredictionHistoryBuilder.history(days: days, surface: surface),
                  let json = try? history.encodedJSON() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("No data yet\n".utf8))
            }
            respond(client, status: 200, contentType: "application/json; charset=utf-8", body: Data(json.utf8))
        case "/metrics":
            guard authorized(headers) else { return unauthorized(client) }
            guard let payload = currentPayload() else {
                return respond(client, status: 503, contentType: "text/plain", body: Data("# no data yet\n".utf8))
            }
            let todayModels = (try? PacerUsageBuilder.todayByModel()) ?? []
            let accounts = (try? PacerAccountsBuilder.list())?.accounts ?? []
            let todayAccounts = accounts.compactMap { account -> PacerMetrics.AccountToday? in
                guard let rows = try? PacerUsageBuilder.todayByModel(
                    account: account.unattributed ? AccountDailyAggregate.unattributedKey : account.id)
                else { return nil }
                return PacerMetrics.AccountToday(account: account, models: rows)
            }
            // Rate limits for every login, not just the active one. The
            // unattributed bucket is skipped: it is a rollup key for turns that
            // predate the activation trail, not an account with windows.
            //
            // Windows only, deliberately — a full snapshot build per account
            // would scan the daily rollups again for numbers `todayAccounts`
            // already has.
            //
            // A scrape passes neither parameter and gets every account, which
            // is what a time-series database wants. A *client* — the pacing
            // skill, in a session pinned to one profile — passes one and gets
            // only its own login, without having to know that account's id.
            var wanted: String?
            switch resolveAccount(query) {
            case .rejected(let message):
                return respond(client, status: 400, contentType: "text/plain", body: Data(message.utf8))
            case .all: wanted = nil
            case .scoped(let key): wanted = key
            }
            let accountLimits = accounts.compactMap { account -> PacerMetrics.AccountLimits? in
                guard !account.unattributed,
                      wanted == nil || account.id == wanted,
                      let limits = try? PacerSnapshotBuilder.limits(account: account.id)
                else { return nil }
                return PacerMetrics.AccountLimits(accountId: account.id, limits: limits)
            }
            let text = PacerMetrics(snapshot: payload, limits: accountLimits,
                                    todayModels: todayModels,
                                    todayAccounts: todayAccounts,
                                    version: appVersion, build: appBuild).prometheusText()
            respond(client, status: 200, contentType: "text/plain; version=0.0.4; charset=utf-8", body: Data(text.utf8))
        case "/v1/stream":
            guard authorized(headers) else { return unauthorized(client) }
            startSSE(client)
        default:
            respond(client, status: 404, contentType: "text/plain", body: Data("Not Found\n".utf8))
        }
    }

    /// Resolve an optional `?account=` into a rollup key.
    ///
    /// Absent means unscoped — the default, because a consumer that did not
    /// ask to be scoped must not be. For the usage endpoints that is every
    /// account; for `/v1/snapshot` it is every account's cost and tokens with
    /// the active login's limits, which is what that payload has always meant.
    /// An id that does not exist is a 400 naming the legal values rather than
    /// an empty 200, which would look exactly like an account that simply had
    /// a quiet month.
    enum AccountQuery {
        case all
        case scoped(String)
        case rejected(String)
    }

    private func resolveAccount(_ query: [String: String]) -> AccountQuery {
        // `?config_dir=` is the parallel-accounts case: a Claude Code session
        // pinned to its own profile knows the directory it was handed and
        // nothing else, and only Pacer knows whose login is in it. Resolving it
        // here is what stops such a session pacing against the *default*
        // login's windows, which are a different account's entirely.
        //
        // A root Pacer has never seen a login in falls through to unscoped
        // rather than erroring: a brand-new profile is a real state, and the
        // active login is the right answer until something is observed in it.
        if let dir = query["config_dir"], !dir.isEmpty {
            if let resolved = (try? PacerAccountsBuilder.resolve(configDir: dir)) ?? nil {
                return .scoped(resolved)
            }
            if query["account"] == nil { return .all }
        }
        guard let raw = query["account"], !raw.isEmpty else { return .all }
        do {
            return .scoped(try PacerAccountsBuilder.resolve(raw))
        } catch let PacerAccountsBuilder.ResolveError.unknownAccount(known) {
            return .rejected("Unknown account \"\(raw)\". Known: \(known.joined(separator: ", "))\n")
        } catch {
            return .rejected("Could not read accounts\n")
        }
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
        if let last = scopeAnnouncedAt[accountId], now.timeIntervalSince(last) < 60 { return }
        scopeAnnouncedAt[accountId] = now
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

    private func authorized(_ headers: [String: String]) -> Bool {
        guard let token = config?.token else { return true }
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
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: - Payload

    /// `account` is a resolved rollup key, or nil for the unscoped payload.
    /// A build failure falls back to the last good payload *for that same
    /// scope* — never another account's, which is the one substitution that
    /// would be worse than an error.
    private func currentPayload(account: String? = nil) -> PacerSnapshotPayload? {
        let key = account ?? ""
        if let hit = cached[key], Date().timeIntervalSince(hit.at) < Self.cacheTTL {
            return hit.payload
        }
        guard let payload = try? PacerSnapshotBuilder.build(account: account) else {
            return cached[key]?.payload
        }
        cached[key] = (payload, Date())
        return payload
    }

    // MARK: - SSE

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
                if let payload = self.currentPayload(), let json = try? payload.encodedJSON() {
                    self.writeEvent(client, event: "snapshot", json: json)
                }
            }
        })
    }

    private func broadcast() {
        guard !sseClients.isEmpty else { cached.removeAll(); return }
        cached.removeAll() // freshest projection for subscribers
        guard let payload = currentPayload(), let json = try? payload.encodedJSON() else { return }
        for client in sseClients.values { writeEvent(client, event: "snapshot", json: json) }
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

    private func installRecomputeObserver() {
        recomputeObserver = NotificationCenter.default.addObserver(
            forName: .pacerEngineDidRecompute, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.broadcast() }
        }
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
