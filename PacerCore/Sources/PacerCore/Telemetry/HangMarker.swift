import Foundation

/// The hang the app is in right now, written to disk while it lasts, so the
/// next launch can tell a hang that ended in a kill (force quit, an update
/// replacing a frozen app, a crash) from one the app came out of. Written by
/// `HangReporter` when `HangWatch` reports `.began`, moved on at every
/// `.continuing`, removed at `.ended`.
///
/// A small JSON file in the App Group container, not defaults: a defaults
/// write posts `UserDefaults.didChangeNotification` to observers queued on a
/// main thread that is, by definition, stuck.
public struct HangMarker: Codable, Sendable, Equatable {
    /// Wall-clock time the stretch began.
    public var startedAt: Date
    /// The last time the watch saw the main thread still stuck.
    public var lastSeenAt: Date
    /// The stretch began at launch, before the run loop first slept.
    public var atLaunch: Bool
    /// The app version that hung (`CFBundleShortVersionString`): the next
    /// launch may be a newer one.
    public var version: String

    public init(startedAt: Date, lastSeenAt: Date, atLaunch: Bool, version: String) {
        self.startedAt = startedAt; self.lastSeenAt = lastSeenAt
        self.atLaunch = atLaunch; self.version = version
    }

    /// How long the main thread was seen stuck: a lower bound when the app
    /// ended during the hang.
    public var duration: TimeInterval { max(0, lastSeenAt.timeIntervalSince(startedAt)) }

    public static let fileName = "hang-in-progress.json"

    /// The marker's place in the App Group container; nil where the container
    /// cannot be resolved.
    public static func defaultURL() -> URL? {
        try? PacerStore.sharedContainerURL().appendingPathComponent(fileName)
    }

    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The marker at `url`, if one is there and readable.
    public static func read(at url: URL) -> HangMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HangMarker.self, from: data)
    }

    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The marker a previous process left, removed so it is reported once.
    /// An unreadable file is removed too: it can only be a torn write.
    public static func takeLeftover(at url: URL) -> HangMarker? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        defer { remove(at: url) }
        return read(at: url)
    }
}
