import Foundation
import SwiftData

/// What an arena model's grade depends on besides the cycle it grades: the
/// port itself (its `ArenaModelSpec.version`, and its children's, since a
/// parent forecasts through them) and, for a model that reads spend, the
/// prices and the imported history that spend was computed from.
///
/// Every grade is stored with its fingerprint (`EngineEvalOutcome.inputs`).
/// When a model's fingerprint moves (a port fixed, prices recomputed, the
/// transcripts re-imported) the scorer treats its stored grades as missing
/// and grades them again, in place and in its usual order (cheap models
/// first, newest cycles first, within the CPU budget). Until a grade is
/// replaced the old one still counts, so selection never waits on it.
public struct ArenaGradeInputs: Sendable, Equatable {
    /// `ClaudeCodeMetaKey.costRecomputeVersion`: bumped when every price is
    /// recomputed. A catalog refresh that reprices a few buckets does not
    /// move it, deliberately: re-grading two dozen models over months for a
    /// correction to a handful of turns would cost hours of CPU for a change
    /// that moves a meter-points-per-dollar ratio by a rounding error.
    public var pricing: String
    /// `ClaudeCodeMetaKey.scanVersion`: bumped when the transcripts are read
    /// again from scratch, which can change which turns (and so what spend)
    /// the history holds.
    public var history: String

    public init(pricing: String = "0", history: String = "0") {
        self.pricing = pricing; self.history = history
    }

    /// The generations the store holds now; "0" for one not written yet.
    public static func read(container: ModelContainer) -> ArenaGradeInputs {
        let context = ModelContext(container)
        func value(_ key: String) -> String {
            var d = FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == key })
            d.fetchLimit = 1
            return (try? context.fetch(d))?.first?.value ?? "0"
        }
        return ArenaGradeInputs(pricing: value(ClaudeCodeMetaKey.costRecomputeVersion),
                                history: value(ClaudeCodeMetaKey.scanVersion))
    }

    /// Models (and helpers) that read only meter readings, never spend. Any
    /// other name in a model's tree makes its grade depend on prices; a model
    /// wrongly left out of this list only costs an unneeded re-grade.
    public static let meterOnly: Set<String> = [
        "naive-flat", "port-engine-recent-rate", "port-engine-kalman-trend",
        "fm-timestral-5m-meter", "fm-timestral-28m-meter", "fm-timestral-123m-meter", "fm-timestral-209m-meter",
        "g2-01-haiku-weekly-209m-extended", "fm-chronos2-meter", "fm-timesfm25-meter", "g2-07-opus-limit",
    ]

    /// `spec`'s fingerprint: `m<version>` (with a hash of its children's
    /// versions when any is past 1), then `.p<pricing>.h<history>` when its
    /// tree reads spend.
    public func fingerprint(_ spec: ArenaModelSpec, registry: [String: ArenaModelSpec]) -> String {
        var tree: [String: Int] = [:]
        var stack = [spec]
        while let s = stack.popLast() {
            guard tree[s.name] == nil else { continue }
            tree[s.name] = s.version
            stack += s.children.compactMap { registry[$0] }
        }
        // A child missing from the registry is still in the tree by name.
        for c in spec.children where tree[c] == nil { tree[c] = 1 }
        var model = "m\(spec.version)"
        let children = tree.filter { $0.key != spec.name }
        if children.values.contains(where: { $0 != 1 }) {
            let canonical = children.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            var hash: UInt64 = 0xcbf29ce484222325
            for b in canonical.utf8 { hash ^= UInt64(b); hash = hash &* 0x100000001b3 }
            model += "-" + String(format: "%08x", UInt32(truncatingIfNeeded: hash))
        }
        let readsSpend = tree.keys.contains { !Self.meterOnly.contains($0) }
        return readsSpend ? "\(model).p\(pricing).h\(history)" : model
    }
}
