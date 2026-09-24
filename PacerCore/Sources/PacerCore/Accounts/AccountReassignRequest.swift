import Foundation

/// A request, dropped next to the store, to move a stretch of history from one
/// account to another — see `AccountTrailRecorder.reassign`.
///
/// It is picked up by the running app's scan loop rather than by a separate
/// process opening the store. That keeps the store single-writer, needs no
/// quit-and-relaunch, and puts the repair through exactly the path the
/// automatic corrections use: the trail edit, the re-stamp, and a rebuild of
/// every rollup the moved turns feed. The cost while no request exists is one
/// `stat` per cycle.
///
///     {"from": "2026-01-01T12:00:00Z", "to": "2026-01-01T18:00:00Z",
///      "wrongAccount": "<account id>", "rightAccount": "<account id>"}
///
/// The file may also hold an array of these. `make reassign-account` writes it.
public struct AccountReassignRequest: Codable, Sendable, Equatable {
    public let from: Date
    public let to: Date
    public let wrongAccount: String
    public let rightAccount: String

    public init(from: Date, to: Date, wrongAccount: String, rightAccount: String) {
        self.from = from
        self.to = to
        self.wrongAccount = wrongAccount
        self.rightAccount = rightAccount
    }

    /// Where the request lives, beside the store it applies to. nil for an
    /// in-memory store, so tests and harnesses can never pick up a request
    /// meant for the real one.
    public static func url(storeURL: URL?) -> URL? {
        storeURL?.deletingLastPathComponent().appending(path: fileName)
    }

    public static let fileName = "account-reassign.json"

    public enum LoadError: Error, Equatable {
        case malformed
        case emptyRange
        case sameAccount
        case unknownAccount(String)
    }

    /// Parse and validate. Account ids must be ones the store knows, because a
    /// typo would otherwise silently move nothing — or move everything to an
    /// account that does not exist.
    public static func parse(_ data: Data, knownAccounts: Set<String>) throws -> [AccountReassignRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let requests: [AccountReassignRequest]
        if let many = try? decoder.decode([AccountReassignRequest].self, from: data) {
            requests = many
        } else if let one = try? decoder.decode(AccountReassignRequest.self, from: data) {
            requests = [one]
        } else {
            throw LoadError.malformed
        }
        for r in requests {
            guard r.from < r.to else { throw LoadError.emptyRange }
            guard r.wrongAccount != r.rightAccount else { throw LoadError.sameAccount }
            for id in [r.wrongAccount, r.rightAccount] where !knownAccounts.contains(id) {
                throw LoadError.unknownAccount(id)
            }
        }
        return requests
    }
}
