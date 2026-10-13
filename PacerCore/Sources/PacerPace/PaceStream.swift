import Foundation
import Network

/// Wakes a sleeping `pacer wait` the moment Pacer pushes news, instead of at
/// the next `--interval` (#256).
///
/// `wait` used to re-read Pacer every 15 s, so a login switch that restored
/// headroom was noticed up to 15 s late, and every waiting session made a
/// request every 15 s for as long as it waited. Pacer's `/v1/stream` already
/// says when something changed: `account` when the login moves (sent by the
/// poller within half a second, #254) and `snapshot` when the numbers are
/// rebuilt. A sleep here returns early on either; `wait` then reads Pacer as
/// it always did, so what decides is unchanged, only when it looks.
///
/// A plain TCP connection (`NWConnection`), not `URLSession`: on macOS 15 and
/// 26 `URLSession` held a trickle of short events back, so the sleep never
/// woke there (it did on 27). Pacer's server writes the stream raw, one frame
/// per send, so reading lines off the socket is all a client needs.
///
/// Nothing depends on the stream: with the API off (the store is read
/// instead), a token the stream rejects, or a connection that drops, a sleep
/// simply lasts its full interval. Opened on the first sleep, so commands
/// that never sleep never connect.
final class PaceStream: @unchecked Sendable {

    /// The events worth waking for.
    static let wakingEvents: Set<String> = ["account", "snapshot"]

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let request: Data
    private let queue = DispatchQueue(label: "com.ericandrechek.pacer.cli.stream")
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var connection: NWConnection?
    // On `queue` only.
    private var buffer = Data()
    private var sawStatus = false
    /// A wake is already queued: a burst of events is one early look, not a
    /// run of them. Guarded by `lock`.
    private var pending = false

    /// Only for a loopback, plain-HTTP API, like the store fallback: a remote
    /// `PACER_API` is somebody else's machine, and Pacer serves no TLS.
    init?(apiBase: String, token: String?) {
        guard let url = URL(string: apiBase + "/v1/stream"), PaceOffline.isLoopback(url),
              url.scheme?.lowercased() == "http", let hostName = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else { return nil }
        self.host = NWEndpoint.Host(hostName)
        self.port = port
        var head = "GET \(url.path) HTTP/1.1\r\nHost: \(hostName):\(port.rawValue)\r\n"
            + "Accept: text/event-stream\r\nCache-Control: no-cache\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        request = Data((head + "\r\n").utf8)
    }

    /// Sleep up to `seconds`, less if Pacer pushes an event meanwhile.
    func sleep(_ seconds: TimeInterval) {
        connectIfNeeded()
        _ = wake.wait(timeout: .now() + seconds)
        lock.withLock { pending = false }
    }

    private func connectIfNeeded() {
        lock.withLock {
            guard connection == nil else { return }
            let connection = NWConnection(host: host, port: port, using: .tcp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                if case .ready = state {
                    connection.send(content: self.request, completion: .contentProcessed { _ in })
                    self.receive(on: connection)
                }
            }
            connection.start(queue: queue)
            self.connection = connection
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, !self.consume(data) {
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    /// Whole lines only; a partial one waits for the rest. Returns false to
    /// give up: anything but a 200 (a rejected token, a 503) is no stream.
    private func consume(_ data: Data) -> Bool {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !sawStatus {
                sawStatus = true
                guard line.hasPrefix("HTTP/1."), line.split(separator: " ").dropFirst().first == "200"
                else { return false }
                continue
            }
            guard line.hasPrefix("event:") else { continue }
            let name = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            guard Self.wakingEvents.contains(name) else { continue }
            let signal: Bool = lock.withLock {
                guard !pending else { return false }
                pending = true
                return true
            }
            if signal { wake.signal() }
        }
        return true
    }
}
