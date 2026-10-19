import Foundation

/// The verdict file `gate` writes and `status` reads, in `~/.claude/pace/`:
/// `state-<run>.json` when a run names itself (`PACE_RUN`), else
/// `state-session-<first 8 of CLAUDE_CODE_SESSION_ID>.json` in a Claude Code
/// session (#265), else `state.json`. `PACE_STATE` or `--state` names any
/// other path.
///
/// The format is the bash `pace.sh`'s, byte for byte: a verdict written by the
/// script before an update must still read after it, and the skill's SKILL.md
/// documents the directory. Fields are read back the way `pace.sh` read them (the value
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
        /// The gate's `--eta` horizon in seconds (0 = none) and `--window`,
        /// so a later `wait` judges by the same rules (#258).
        var eta: Int = 0
        var window: String = "all"
        /// The model was resolved from `auto` (#264): a later `wait` resolves
        /// it again instead of keeping what the session ran then.
        var modelAuto = false
        /// Points below the safe limit the gate stopped at (#263).
        var margin = 0
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
          "eta": \(v.eta),
          "window": "\(v.window)",
          "autoModel": \(v.modelAuto),
          "margin": \(v.margin),
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

    /// The part of a session id a default state file is named by: its first
    /// 8 characters, and only ones safe in a file name. Nil without an id.
    static func sessionTag(_ id: String?) -> String? {
        guard let id else { return nil }
        let safe = id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return safe.isEmpty ? nil : String(safe.prefix(8))
    }

    /// How long another session's default verdict is kept. Any verdict is
    /// stale after `--max-age` (15 minutes by default), so a week is only
    /// about not deleting the file of a session that is still around.
    static let sessionFileLifetime: TimeInterval = 7 * 86_400

    /// Remove other sessions' default state files (and their refresh locks)
    /// untouched for `sessionFileLifetime`. One file per Claude Code session
    /// would otherwise accumulate for ever. Only `state-session-*` files:
    /// named runs and `state.json` are somebody's choice and stay.
    static func pruneSessionFiles(beside path: String, now: Date) {
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasPrefix("state-session-") && name.hasSuffix(".json") {
            let file = (dir as NSString).appendingPathComponent(name)
            guard file != path,
                  let modified = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > sessionFileLifetime else { continue }
            try? fm.removeItem(atPath: file)
            try? fm.removeItem(atPath: file + ".lock")
        }
    }

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
