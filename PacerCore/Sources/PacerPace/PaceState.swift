import Foundation

/// The verdict file `gate` writes and `status` reads: `~/.claude/pace/state.json`,
/// or `state-<run>.json` when a run names itself.
///
/// The format is `pace.sh`'s, byte for byte, because the two will share these
/// files while `pace.sh` is being replaced, and the skill's SKILL.md documents
/// the directory. Fields are read back the way `pace.sh` read them (the value
/// between the 3rd and 4th quote on the line naming the key), not by a JSON
/// decoder: a file someone edited by hand, or one cut short, still answers
/// what it can.
struct PaceStateFile {
    let path: String

    struct Verdict {
        let status: String
        let tripWindow: String
        let model: String
        let cap: PaceRules.Cap
        let usedPercent: String?
        let resetsIn: String?
        let note: String
    }

    /// Written to a temporary file and renamed into place, so a reader never
    /// sees half a verdict.
    func write(_ v: Verdict, now: Date) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cap: String
        switch v.cap {
        case .safe: cap = "\"safe\""
        case .value(let text): cap = text
        }
        let body = """
        {
          "status": "\(v.status)",
          "tripWindow": "\(v.tripWindow)",
          "model": "\(v.model)",
          "cap": \(cap),
          "usedPercent": \(v.usedPercent ?? "null"),
          "resetsInSeconds": \(v.resetsIn ?? "null"),
          "note": "\(v.note)",
          "updatedAt": "\(PaceFormat.utcStamp(now))"
        }

        """
        let tmp = "\(path).tmp.\(ProcessInfo.processInfo.processIdentifier)"
        guard (try? body.write(toFile: tmp, atomically: false, encoding: .utf8)) != nil else { return }
        // rename(2), like `mv`: replaces the old file in one step.
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp) }
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    private var text: String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// awk -F'"' '/"key"/ { print $4; exit }'
    func quoted(_ key: String) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.contains("\"\(key)\"") {
            let fields = line.split(separator: "\"", omittingEmptySubsequences: false)
            return fields.count >= 4 ? String(fields[3]) : ""
        }
        return nil
    }

    /// awk -F': ' '/"key"/ { gsub(/[ ,]/, "", $2); print $2; exit }'
    func bare(_ key: String) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.contains("\"\(key)\"") {
            let parts = line.components(separatedBy: ": ")
            guard parts.count >= 2 else { return "" }
            return parts[1].filter { $0 != " " && $0 != "," }
        }
        return nil
    }

    /// Seconds since the verdict was written, from its own `updatedAt` (a copy
    /// keeps that; it does not keep the mtime). Nil when it cannot be read,
    /// which skips the staleness check rather than failing it.
    func age(now: Date) -> Int? {
        guard let stamp = quoted("updatedAt"), !stamp.isEmpty,
              let written = PaceFormat.isoFormatter.date(from: stamp) else { return nil }
        return Int(floor(now.timeIntervalSince1970)) - Int(written.timeIntervalSince1970)
    }
}
