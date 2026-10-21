import Foundation

extension ParsedUsageEntry {
    /// Whether this copy, read from `file`, is the one to keep over `other`,
    /// read from `otherFile` — `other` sharing its `dedupKey`.
    ///
    /// The one rule both ingest paths pick a message's copy by (#334). It is
    /// `supersedes` (correctness rule 7: the finished copy, else the larger
    /// output), made total: copies `supersedes` can't separate go to the
    /// earliest, then to the file whose path sorts first by bytes.
    ///
    /// The tie-break is not a formality. On a real 13 GB transcript tree, 320k
    /// of 744k assistant lines tie their key's best copy on finished and
    /// output: subagent transcripts replay their parent's messages, and one
    /// finished message can be logged several times, seconds apart. Before
    /// this, the line scanner kept whichever copy it read first, in file-mtime
    /// order, and the bulk importer the earliest; a new row's timestamp then
    /// depended on which path wrote it, and on when a file was last touched.
    /// Neither file order nor read order appears here, so the answer is the
    /// same whichever path reads the copies and in whatever order.
    ///
    /// `ArchiveImporter`'s SQL orders its candidates the same way; the
    /// ingest-parity test pins the two together.
    public func isKept(from file: String, over other: ParsedUsageEntry, from otherFile: String) -> Bool {
        if supersedes(other) { return true }
        if other.supersedes(self) { return false }
        if timestamp != other.timestamp { return timestamp < other.timestamp }
        return file.utf8.lexicographicallyPrecedes(otherFile.utf8)
    }
}

/// One copy per dedup key — the one `ParsedUsageEntry.isKept` picks — in the
/// order each key first appeared. Entries without a key all pass through.
///
/// Both ingest paths reduce through this before anything reaches the
/// persister, so the persister sees each message once per scan. It used to
/// see the line scanner's every improvement instead: the first mid-stream
/// copy of a new message was inserted and then upgraded in the same pass,
/// leaving the row with the finished copy's tokens and the partial copy's
/// timestamp, while the bulk importer inserted the finished copy outright —
/// same tokens, a different row, and a different upgrade count for the same
/// transcripts (#334).
public struct CopySelection {
    /// The kept copies, in first-appearance order.
    public private(set) var entries: [ParsedUsageEntry] = []
    /// The file each kept copy came from, parallel to `entries`.
    private var files: [String] = []
    private var slotByKey: [String: Int] = [:]
    /// Copies of a key already held: dropped, or replacing the one held.
    public private(set) var repeats = 0

    public init() {}

    public mutating func reserveCapacity(_ n: Int) {
        entries.reserveCapacity(n)
        files.reserveCapacity(n)
        slotByKey.reserveCapacity(n)
    }

    /// The kept copies, handed over: the selection is left empty, so a
    /// caller that sorts them sorts the only reference rather than a copy of
    /// a few hundred thousand entries.
    public mutating func takeEntries() -> [ParsedUsageEntry] {
        defer { self = CopySelection() }
        return entries
    }

    public mutating func offer(_ entry: ParsedUsageEntry, from file: String) {
        guard let key = entry.dedupKey else {
            entries.append(entry)
            files.append(file)
            return
        }
        if let slot = slotByKey[key] {
            repeats += 1
            if entry.isKept(from: file, over: entries[slot], from: files[slot]) {
                entries[slot] = entry
                files[slot] = file
            }
            return
        }
        slotByKey[key] = entries.count
        entries.append(entry)
        files.append(file)
    }
}
