import Foundation

/// Reads one session's transcripts for what the data canary needs from them
/// (`SessionTotalsCanary.TranscriptEvidence`): the requests Claude Code logged
/// and answered, and the lines that mark its untranscribed calls.
///
/// Deliberately not the ingest parser: the canary checks the parser, so it
/// reads the lines its own way. Claude Code writes compact JSON, so each line
/// is first searched for a few fixed byte strings and only the few that hold
/// one are decoded: a request (`"type":"api-request"`), a usage line that
/// names its request (`"requestRef":"`), a recap or a compaction
/// (`"subtype":"…"`). Quoted keys can only appear unescaped where they are
/// keys, so text inside a message can't match. Streams line by line
/// (correctness rule 3); a line that does not decode is skipped (rule 6).
public enum TranscriptEvidenceReader {

    /// What one pass found, before the store is asked about the requests.
    public struct Scan: Sendable, Equatable {
        /// Dedup key (`message.id:requestId`) of each answered request's usage
        /// line, by request. A request answered only by `<synthetic>` lines
        /// (an error) is not here: Pacer drops those by rule.
        public var answered: [String: String] = [:]
        /// Request ids Claude Code logged for this session.
        public var logged: Set<String> = []
        public var compactions = 0
        public var recaps = 0
        public var desktop = false

        public init() {}

        /// Logged requests no usage line answers.
        public var unanswered: Int { logged.subtracting(answered.keys).count }

        /// The answered requests' dedup keys, each once.
        public var answeredKeys: Set<String> { Set(answered.values) }
    }

    private struct Line: Decodable {
        let type: String?
        let subtype: String?
        let id: String?
        let sessionId: String?
        let timestamp: String?
        let requestRef: String?
        let requestId: String?
        let entrypoint: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
        }
    }

    private static let decoder = JSONDecoder()
    private static let requestNeedle = Data(#""type":"api-request""#.utf8)
    private static let answerNeedle = Data(#""requestRef":""#.utf8)
    private static let subtypeNeedle = Data(#""subtype":""#.utf8)
    private static let desktopNeedle = Data(#""entrypoint":"claude-desktop""#.utf8)

    /// Read `files`, the transcripts of `sessionId`. Markers count only inside
    /// `window` (the counters' span); requests count over the whole session.
    public static func read(
        files: [URL], sessionId: String, window: ClosedRange<Date>?
    ) -> Scan {
        var scan = Scan()
        for file in files {
            forEachLine(of: file) { line in
                take(line, sessionId: sessionId, window: window, into: &scan)
            }
        }
        return scan
    }

    static func take(_ line: Data, sessionId: String, window: ClosedRange<Date>?,
                     into scan: inout Scan) {
        let answers = line.range(of: answerNeedle) != nil
        if !scan.desktop, line.range(of: desktopNeedle) != nil { scan.desktop = true }
        guard answers
                || line.range(of: requestNeedle) != nil
                || line.range(of: subtypeNeedle) != nil,
              let raw = try? decoder.decode(Line.self, from: line)
        else { return }
        switch raw.type {
        case "assistant":
            guard let ref = raw.requestRef, scan.answered[ref] == nil,
                  let model = raw.message?.model, !model.isEmpty,
                  model != JSONLLineParser.syntheticModelSentinel,
                  let messageId = raw.message?.id, let requestId = raw.requestId
            else { return }
            scan.answered[ref] = "\(messageId):\(requestId)"
        case "api-request":
            // A resume can carry another session's log lines into this file.
            guard let id = raw.id, raw.sessionId == nil || raw.sessionId == sessionId else { return }
            scan.logged.insert(id)
        case "system":
            guard raw.subtype == "compact_boundary" || raw.subtype == "away_summary" else { return }
            if let window {
                guard let stamp = raw.timestamp.flatMap(JSONLLineParser.parseTimestampForImport),
                      window.contains(stamp) else { return }
            }
            if raw.subtype == "compact_boundary" { scan.compactions += 1 } else { scan.recaps += 1 }
        default:
            return
        }
    }

    /// Every complete line of `url`, a chunk at a time. A trailing line with
    /// no newline is still being written and is left out, as the scanner
    /// leaves it.
    static func forEachLine(of url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var pending = Data()
        // A pool per chunk, as `JSONLScanner` does: reads come back
        // autoreleased and nothing else drains them during one long pass.
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                return false
            }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                if newline > start { body(Data(pending[start..<newline])) }
                start = pending.index(after: newline)
            }
            pending.removeSubrange(pending.startIndex..<start)
            return true
        }) {}
    }
}
