import Foundation
import PacerCore

/// Where a `pace` read goes when nothing answers on Pacer's port: the store,
/// through `PacerOfflineAPI` (#194).
///
/// Opened on first need, not at launch. `status` never reads Pacer at all, and
/// a run whose API answers should not pay for opening a database it never
/// reads, or touch the App Group container for no reason.
///
/// Only for a loopback URL. `PACER_API` pointed at another machine is a
/// question about that machine, and this one's store is not its answer.
public final class PaceOffline: @unchecked Sendable {

    private let open: () -> PacerOfflineAPI?
    private let now: () -> Date
    private let lock = NSLock()
    private var opened = false
    private var api: PacerOfflineAPI?

    public init(now: @escaping () -> Date = Date.init, open: @escaping () -> PacerOfflineAPI?) {
        self.now = now
        self.open = open
    }

    /// The shared store, read-only, as the installed CLI reads it.
    public static var store: PaceOffline {
        PaceOffline { (try? PacerOfflineAPI.readOnlyContainer()).map { PacerOfflineAPI(container: $0) } }
    }

    /// The answer Pacer would have given `request`, or nil when there is none
    /// to give here: not a loopback URL, a route `PacerOfflineAPI` does not
    /// serve, or no store this process can open.
    public func answer(_ request: URLRequest) -> PaceResponse? {
        guard let url = request.url, Self.isLoopback(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard let api = resolved(),
              let answer = api.respond(path: components.path, query: query, now: now()) else { return nil }
        return PaceResponse(status: answer.status, body: answer.body)
    }

    private func resolved() -> PacerOfflineAPI? {
        lock.withLock {
            if !opened {
                opened = true
                api = open()
            }
            return api
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
}
