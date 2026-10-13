import Foundation

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
/// Nothing depends on the stream: with the API off (the store is read
/// instead), a token the stream rejects, or a connection that drops, a sleep
/// simply lasts its full interval. Opened on the first sleep, so commands
/// that never sleep never connect.
final class PaceStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// The events worth waking for.
    static let wakingEvents: Set<String> = ["account", "snapshot"]

    private let request: URLRequest
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var session: URLSession?
    private var buffer = ""
    /// A wake is already queued: a burst of events is one early look, not a
    /// run of them.
    private var pending = false

    /// Only for a loopback API, like the store fallback: a remote `PACER_API`
    /// is somebody else's machine.
    init?(apiBase: String, token: String?) {
        guard let url = URL(string: apiBase + "/v1/stream"), PaceOffline.isLoopback(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // The server sends a keepalive every 20 s; a stream is idle by nature.
        request.timeoutInterval = 24 * 3600
        self.request = request
    }

    /// Sleep up to `seconds`, less if Pacer pushes an event meanwhile.
    func sleep(_ seconds: TimeInterval) {
        connectIfNeeded()
        _ = wake.wait(timeout: .now() + seconds)
        lock.withLock { pending = false }
    }

    private func connectIfNeeded() {
        lock.withLock {
            guard session == nil else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 24 * 3600
            configuration.timeoutIntervalForResource = 7 * 24 * 3600
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            session.dataTask(with: request).resume()
            self.session = session
        }
    }

    // MARK: - URLSessionDataDelegate (on the session's serial queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        // Whole lines only; a partial one waits for the rest.
        while let newline = buffer.firstIndex(of: "\n") {
            let line = buffer[..<newline].trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...newline)
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
    }
}
