import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Pages a frozen COPY of a real store's `TokenSample` table the two ways
/// `ModelWalk` has (#394) and measures each: offset windows, written out here
/// as the walk did before, against the walk's own row-id pages. One mode per
/// run, each on its own clone, so the file cache one leaves is the next one's
/// to inherit only if they're run back to back on purpose:
///
///     sqlite3 "<store>" ".backup '/tmp/keyset/pristine.sqlite'"
///     cp -c /tmp/keyset/pristine.sqlite /tmp/keyset/a.sqlite
///     PACER_KEYSET_PROBE_STORE=/tmp/keyset/a.sqlite PACER_KEYSET_PROBE_MODE=offset-read \
///     PACER_ISOLATED_DEFAULTS=1 swift test --filter RealStoreKeysetProbe
///
/// Modes:
/// - `offset-read` / `keyset-read`: every row, read-only, the columns the
///   dedup preload reads.
/// - `drain-stamp` / `keyset-stamp`: the stored-hour backfill
///   (`markEverySampleDirty`'s write) over a copy whose every row predates
///   the field — prepare it once with `UPDATE ZTOKENSAMPLE SET ZLOCALHOUR = -1`.
///   `drain-stamp` refetches from the top each page, as `.drain` did.
@Suite("Real-store keyset probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_KEYSET_PROBE_STORE"] != nil))
struct RealStoreKeysetProbe {

    func log(_ s: String) {
        print("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [keyset] \(s)")
    }

    @ScanActor
    @Test func pageTheTable() throws {
        let env = ProcessInfo.processInfo.environment
        let storeURL = URL(fileURLWithPath: try #require(env["PACER_KEYSET_PROBE_STORE"]))
        let mode = try #require(env["PACER_KEYSET_PROBE_MODE"])
        if let live = try? PacerStore.storeURL() {
            let same = storeURL.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
            #expect(!same)
            guard !same else { return }
        }
        let container = try PacerStore.makeModelContainer(at: storeURL)
        let pageSize = ModelWalk.pageSize
        var slim = FetchDescriptor<TokenSample>()
        slim.propertiesToFetch = [\.dedupKey, \.date, \.model, \.projectPath, \.sessionId,
                                  \.sampledAt, \.outputTokens, \.localHour]
        let unstamped = FetchDescriptor<TokenSample>(predicate: #Predicate { $0.localHour < 0 })

        var pageMs: [Double] = []
        var pageStart = Date()
        var rows = 0
        var digest: UInt64 = 0
        func note(_ s: TokenSample) {
            rows += 1
            digest &+= UInt64(bitPattern: s.outputTokens) &* 0x9E37_79B9_7F4A_7C15
            if rows.isMultiple(of: pageSize) {
                pageMs.append(Date().timeIntervalSince(pageStart) * 1000)
                pageStart = Date()
            }
        }

        let sampler = ResourceSampler()
        sampler.start()
        let started = Date()
        switch mode {
        case "offset-read":
            var page = slim
            page.fetchLimit = pageSize
            var offset = 0
            while true {
                page.fetchOffset = offset
                let n = try autoreleasepool { () throws -> Int in
                    let fetched = try ModelContext(container).fetch(page)
                    for s in fetched { note(s) }
                    return fetched.count
                }
                offset += n
                if n < pageSize { break }
            }
        case "keyset-read":
            try ModelWalk.forEach(slim, in: container) { note($0) }
        case "drain-stamp":
            var page = unstamped
            page.fetchLimit = pageSize
            while true {
                let n = try autoreleasepool { () throws -> Int in
                    let context = ModelContext(container)
                    let fetched = try context.fetch(page)
                    for s in fetched {
                        note(s)
                        s.localHour = Calendar.current.component(.hour, from: s.sampledAt)
                    }
                    if context.hasChanges { try context.save() }
                    return fetched.count
                }
                if n < pageSize { break }
            }
        case "keyset-stamp":
            let owner = ModelContext(container)
            try ModelWalk.update(unstamped, in: container, owner: owner) { s in
                note(s)
                s.localHour = Calendar.current.component(.hour, from: s.sampledAt)
            }
        default:
            Issue.record("unknown mode \(mode)")
            return
        }
        pageMs.append(Date().timeIntervalSince(pageStart) * 1000)
        let wall = Date().timeIntervalSince(started)
        let usage = sampler.stop()
        let left = try ModelContext(container).fetchCount(unstamped)

        func at(_ i: Int) -> String { pageMs.indices.contains(i) ? String(format: "%.0f", pageMs[i]) : "-" }
        log(String(format: "%@: %d rows in %d page(s) · %.1f s wall · avg %.2f cores · peak footprint %.0f MB",
                   mode, rows, pageMs.count, wall, usage.averageCores, Double(usage.peakFootprint) / 1e6))
        log("page ms: first \(at(0)) · 10th \(at(9)) · 20th \(at(19)) · 30th \(at(29)) · last \(at(pageMs.count - 1))"
            + String(format: " · max %.0f", pageMs.max() ?? 0))
        log("digest \(String(digest, radix: 16)) · unstamped left \(left)")
        if let out = env["PACER_KEYSET_PROBE_OUT"] {
            let line = String(format: "%@\trows=%d\tpages=%d\twall_s=%.1f\tpeak_mb=%.0f\tdigest=%@\tleft=%d\tpage_ms=%@\n",
                              mode, rows, pageMs.count, wall, Double(usage.peakFootprint) / 1e6,
                              String(digest, radix: 16), left,
                              pageMs.map { String(format: "%.0f", $0) }.joined(separator: ","))
            if let h = FileHandle(forWritingAtPath: out) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try h.close()
            } else {
                try line.write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
    }
}
