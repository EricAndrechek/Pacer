import Foundation

/// Every widget timeline macOS actually asked Pacer for, one line each, in a
/// small file in the App Group container (#318).
///
/// **Why a file.** The app asks WidgetKit to reload a widget
/// (`WidgetRefreshCoordinator`), and WidgetKit decides, against a daily
/// budget, whether and when to call the extension's `getTimeline`. Only the
/// extension sees that call, and it is a separate process whose stderr goes
/// nowhere anyone reads: `Pacer.err.log` is the app's. So the extension
/// appends a line here on every timeline (and snapshot) it builds, and the
/// app reads it back for an hourly `[Widgets]` summary: how many reloads it
/// asked for, how many macOS granted, for which widgets.
///
/// **Format**, one line per call, space-separated so `grep` and `awk` read it:
///
///     2026-10-24T14:03:12.345Z timeline PaceGaugesWidget systemMedium next=2026-10-24T14:08:12Z
///     2026-10-24T14:03:15.002Z snapshot TodayCostWidget systemSmall
///
/// **Cheap and harmless.** No SwiftData. One `open(O_APPEND)` and one
/// `write` per call, well under `PIPE_BUF`, so two writers cannot interleave
/// inside a line. Past `byteCap` the file is rewritten to its newest half.
/// Every failure is swallowed: a widget that cannot log still draws.
public enum WidgetRefreshLog {

    public static let fileName = "widget-refreshes.log"

    /// Rewritten to its newest half past this. A timeline line is about 100
    /// bytes, so this keeps days of them, enough for the 24-hour count.
    public static let byteCap = 512 * 1024

    public enum Event: String, Sendable, Equatable {
        /// `getTimeline`: macOS granted a refresh.
        case timeline
        /// `getSnapshot`: a gallery preview or a transient draw. Not a grant.
        case snapshot
    }

    public struct Entry: Sendable, Equatable {
        public let at: Date
        public let event: Event
        /// The widget's `kind` (`WidgetKinds`).
        public let kind: String
        /// The widget family, "systemSmall" and so on.
        public let family: String
        /// When the timeline asked to be rebuilt; nil for a snapshot.
        public let next: Date?

        public init(at: Date, event: Event, kind: String, family: String, next: Date?) {
            self.at = at
            self.event = event
            self.kind = kind
            self.family = family
            self.next = next
        }
    }

    /// The file in the App Group container, or nil when the container is
    /// not reachable (an unsigned test runner).
    public static func defaultURL() -> URL? {
        try? PacerStore.sharedContainerURL().appendingPathComponent(fileName)
    }

    // MARK: - Lines

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let wholeStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func line(_ entry: Entry) -> String {
        var out = "\(stamp.string(from: entry.at)) \(entry.event.rawValue) \(entry.kind) \(entry.family)"
        if let next = entry.next { out += " next=\(wholeStamp.string(from: next))" }
        return out
    }

    /// Nil for anything that is not a line `line` wrote: a truncated last
    /// line, or a hand edit.
    public static func parse<S: StringProtocol>(_ text: S) -> Entry? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4,
              let at = stamp.date(from: String(parts[0])) ?? wholeStamp.date(from: String(parts[0])),
              let event = Event(rawValue: String(parts[1]))
        else { return nil }
        let next = parts.dropFirst(4)
            .first { $0.hasPrefix("next=") }
            .flatMap { wholeStamp.date(from: String($0.dropFirst(5))) }
        return Entry(at: at, event: event, kind: String(parts[2]), family: String(parts[3]), next: next)
    }

    // MARK: - Writing

    /// Append one line. Never throws, never blocks on anything but the file.
    public static func record(_ event: Event, kind: String, family: String, next: Date?,
                              at: Date = Date(), to url: URL? = defaultURL()) {
        guard let url else { return }
        let data = Data((line(Entry(at: at, event: event, kind: kind, family: family, next: next)) + "\n").utf8)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var info = stat()
        let size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        close(fd)
        if written > 0, size > byteCap { trim(url) }
    }

    /// Keep the newest half, from a line boundary, replaced atomically. A
    /// line another process appends while this runs can be lost; for a
    /// diagnostic count that is fine, and it is rare (once per cap).
    static func trim(_ url: URL, keeping bytes: Int = byteCap / 2) {
        guard let data = try? Data(contentsOf: url), data.count > bytes else { return }
        var tail = data.suffix(bytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: url, options: .atomic)
    }

    // MARK: - Reading

    /// Every line in the file, oldest first; empty when there is none.
    public static func entries(at url: URL? = defaultURL()) -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { parse($0) }
    }

    // MARK: - The hourly summary

    public struct Summary: Sendable, Equatable {
        /// Reloads the app asked WidgetKit for in the last hour.
        public let requested: Int
        /// Timelines macOS asked the extension for in the last hour.
        public let granted: Int
        /// Those, per widget, most first: ("PaceGauges", 3).
        public let grantedByKind: [Kind]
        /// Timelines in the last 24 hours.
        public let granted24h: Int

        public struct Kind: Sendable, Equatable {
            public let name: String
            public let count: Int
        }

        /// "last hour: requested 41, granted 6 (PaceGauges 3 · PaceChart 2 ·
        /// LiveSession 1); last 24 h granted 74"
        public var text: String {
            let kinds = grantedByKind.isEmpty ? ""
                : " (" + grantedByKind.map { "\($0.name) \($0.count)" }.joined(separator: " · ") + ")"
            return "last hour: requested \(requested), granted \(granted)\(kinds); last 24 h granted \(granted24h)"
        }
    }

    /// The summary at `now` from the file's entries and the app's own count
    /// of the reloads it sent in the last hour.
    public static func summary(entries: [Entry], requested: Int, now: Date) -> Summary {
        let timelines = entries.filter { $0.event == .timeline && $0.at <= now }
        let hour = timelines.filter { now.timeIntervalSince($0.at) < 3600 }
        let day = timelines.filter { now.timeIntervalSince($0.at) < 86400 }
        var counts: [String: Int] = [:]
        for entry in hour { counts[shortName(entry.kind), default: 0] += 1 }
        let byKind = counts
            .map { Summary.Kind(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        return Summary(requested: requested, granted: hour.count, grantedByKind: byKind,
                       granted24h: day.count)
    }

    /// "PaceGaugesWidget" → "PaceGauges".
    public static func shortName(_ kind: String) -> String {
        kind.hasSuffix("Widget") && kind.count > "Widget".count ? String(kind.dropLast("Widget".count)) : kind
    }
}
