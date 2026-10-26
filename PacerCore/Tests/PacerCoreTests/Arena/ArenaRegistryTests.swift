import Foundation
import Testing
@testable import PacerCore

/// The merged registry is the contract between the ports: every branch added
/// its own slice, so check the whole for the mistakes a merge can introduce.
@Suite("ArenaRegistry")
struct ArenaRegistryTests {
    /// Children that arrive from branches not merged yet; a spec naming one
    /// still registers, and the runner drops it (a mix renormalises).
    static let allowedMissing: Set<String> = ["port-engine-recent-rate", "port-engine-kalman-trend", "naive-flat"]

    @Test func namesAreUnique() {
        let names = ArenaRegistry.all.map(\.name)
        let dupes = Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys.sorted()
        #expect(dupes.isEmpty, "duplicate registry names: \(dupes)")
    }

    @Test func childrenResolve() {
        let known = Set(ArenaRegistry.all.map(\.name))
        for spec in ArenaRegistry.all {
            for child in spec.children where !known.contains(child) {
                #expect(Self.allowedMissing.contains(child), "\(spec.name) names unregistered child \(child)")
            }
        }
    }

    @Test func weightsAreAvailableOrSkipped() {
        let known = Set(ArenaRegistry.all.map(\.name))
        func chain(_ s: ArenaModelSpec, _ seen: Set<String> = []) -> [String] {
            s.weights + s.children.filter { known.contains($0) && !seen.contains($0) }
                .compactMap { ArenaRegistry.spec($0) }.flatMap { chain($0, seen.union([s.name])) }
        }
        var roster = ["name | targets | children | weights"]
        var ran = 0, skipped = 0
        for spec in ArenaRegistry.all {
            let needed = chain(spec)
            let have = needed.map { TimestralTestWeights.url($0) != nil }
            roster.append("\(spec.name) | \(spec.targets.map { "\($0)" }.sorted().joined(separator: ",")) | "
                + "\(spec.children.joined(separator: ",")) | "
                + "\(needed.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ","))")
            guard !spec.targets.isEmpty else { continue }
            if have.allSatisfy({ $0 }) { ran += 1 } else { skipped += 1 }
        }
        print("ARENA ROSTER (\(ArenaRegistry.all.count) specs; \(ran) runnable here, \(skipped) skipped for missing weights)")
        roster.forEach { print($0) }
        #expect(ran > 0)
    }
}
