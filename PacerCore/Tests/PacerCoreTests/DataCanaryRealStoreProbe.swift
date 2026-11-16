import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The data canary (#353) on frozen COPIES of a real install: the store, the
/// Claude Code config and the transcripts, taken together so the store's
/// cursors describe the copied files. Prints aggregates only, never a session
/// id, a project or a path.
///
///     mkdir /tmp/canary
///     python3 -c "import sqlite3; s = sqlite3.connect('file:<live store>?mode=ro', uri=True); \
///         d = sqlite3.connect('/tmp/canary/pacer.sqlite'); s.backup(d)"
///     cp ~/.claude.json /tmp/canary/claude.json
///     cp -c -Rp ~/.claude/projects /tmp/canary/projects
///     PACER_CANARY_STORE=/tmp/canary/pacer.sqlite \
///     PACER_CANARY_CONFIG=/tmp/canary/claude.json \
///     PACER_CANARY_PROJECTS=/tmp/canary/projects \
///     PACER_CANARY_CURSOR_ROOT=$HOME/.claude/projects \
///     swift test --filter DataCanaryRealStoreProbe
///
/// `PACER_CANARY_CURSOR_ROOT` is the folder the copied `projects` came from:
/// the store's cursors are keyed on the original paths. `cp -p` keeps the
/// modification dates the quiet rule reads. Optional `PACER_CANARY_NOW` (Unix
/// seconds): judge as of the moment the copies were taken.
@Suite("Data canary on a real store copy", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_CANARY_STORE"] != nil))
struct DataCanaryRealStoreProbe {

    @Test("compare a real install's sessions with Claude Code's totals")
    func probe() throws {
        let env = ProcessInfo.processInfo.environment
        let store = URL(fileURLWithPath: try #require(env["PACER_CANARY_STORE"]))
        if let live = try? PacerStore.storeURL() {
            #expect(store.canonicalPathURL != live.canonicalPathURL, "point the probe at a COPY")
        }
        let config = URL(fileURLWithPath: try #require(env["PACER_CANARY_CONFIG"]))
        let projects = URL(fileURLWithPath: try #require(env["PACER_CANARY_PROJECTS"])).canonicalPathURL
        let original = URL(fileURLWithPath: try #require(env["PACER_CANARY_CURSOR_ROOT"])).canonicalPathURL
        let now = env["PACER_CANARY_NOW"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? Date()

        let container = try PacerStore.makeModelContainer(at: store)
        let root = ClaudePathResolver.ResolvedRoot(
            root: projects.deletingLastPathComponent().canonicalPathURL, projectsDirectory: projects)
        let sources = DataCanary.Sources(configFiles: [config], roots: [root])

        // The copy's paths back to the originals the cursors were saved under,
        // in either spelling of a `/private` temp folder.
        let copyPrefixes = [projects.path, "/private" + projects.path].map { $0 + "/" }
        let cursorPath: (String) -> String = { path in
            for prefix in copyPrefixes where path.hasPrefix(prefix) {
                return original.path + "/" + path.dropFirst(prefix.count)
            }
            return path
        }

        for (label, policy) in [
            ("standard (7-day lookback)", SessionTotalsCanary.Policy.standard),
            ("whole history (no lookback)", SessionTotalsCanary.Policy(lookback: 10 * 365 * 86_400)),
        ] {
            let started = Date()
            let report = DataCanary.run(container: container, sources: sources, now: now,
                                        policy: policy, cursorPath: cursorPath)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("[canary-probe] \(label): \(report.sessions) sessions in the config, "
                  + "\(report.checked.count) judged, \(report.checked.count - report.mismatched.count) match, "
                  + "\(report.mismatched.count) mismatch; \(ms) ms")
            let skipped = report.skipped.sorted { $0.key < $1.key }
                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
            print("[canary-probe]   skipped: \(skipped.isEmpty ? "none" : skipped)")
            for session in report.checked.sorted(by: { ($0.ccVersion ?? "") < ($1.ccVersion ?? "") }) {
                let ratios = SessionTotalsCanary.TokenKind.allCases.map { kind -> String in
                    let r = session.comparison.ratios[kind] ?? 1
                    return "\(kind.rawValue)=" + (r.isFinite ? String(format: "%.3f", r) : "inf")
                }.joined(separator: " ")
                let verdict = session.comparison.matched ? "match"
                    : "MISMATCH " + session.comparison.mismatches
                        .map { "\($0.kind.rawValue) \($0.band)" }.joined(separator: ", ")
                print("[canary-probe]   cc \(session.ccVersion ?? "?"): \(ratios) -> \(verdict)")
            }
        }
    }
}
