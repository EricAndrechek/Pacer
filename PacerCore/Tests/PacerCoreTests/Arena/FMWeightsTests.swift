import Foundation
import Testing
@testable import PacerCore

/// The weights pins: the app's store and the build's fetch script name the
/// same files with the same hashes, every registered model's weights are
/// pinned, and ids parse into the folders the store looks in.
@Suite struct FMWeightsTests {
    @Test func fetchScriptPinsMatchTheStore() throws {
        let script = try String(contentsOf: TimestralTestWeights.repoRoot
            .appendingPathComponent("bin/fetch-forecast-weights.sh"), encoding: .utf8)
        var fromScript: [String: [String: (String, Int)]] = [:]
        for line in script.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\"mistralai/") else { continue }
            let f = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: "|").map(String.init)
            #expect(f.count == 4)
            fromScript[f[0], default: [:]][f[1]] = (f[2], Int(f[3]) ?? -1)
        }
        #expect(Set(fromScript.keys) == Set(FMWeights.bundled))
        for (id, files) in fromScript {
            let pins = try #require(ArenaWeightStore.pinned[id])
            #expect(Set(files.keys) == Set(pins.map(\.name)), "\(id)")
            for p in pins {
                #expect(files[p.name]?.0 == p.sha256, "\(id)/\(p.name)")
                #expect(files[p.name]?.1 == p.bytes, "\(id)/\(p.name)")
            }
        }
    }

    @Test func everyRegisteredWeightIsPinned() {
        let fm = ArenaRegistry.fmModels
        #expect(!fm.isEmpty)
        for spec in fm {
            for w in spec.weights { #expect(ArenaWeightStore.pinned[w] != nil, "\(spec.name): \(w)") }
            if let w = spec.config["weights"]?.string { #expect(spec.weights.contains(w), "\(spec.name)") }
        }
    }

    @Test func idsParse() {
        let p = ArenaWeightStore.parse(FMWeights.timestral5M)
        #expect(p?.repo == "mistralai/Timestral-5M")
        #expect(p?.revision == "bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f")
        #expect(ArenaWeightStore.parse("no-revision") == nil)
        #expect(ArenaWeightStore.parse("a/b/c@x") == nil)
        #expect(ArenaWeightStore.localURL(for: "mistralai/Nope@0") == nil)
    }

    @Test func missingWeightsAreReportedNotCrashed() throws {
        let c = try ArenaFixtures.cases().cases[0]
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: ArenaServices(weights: { _ in nil }))
        #expect(throws: ArenaError.weightsUnavailable(FMWeights.timestral5M)) {
            try runner.forecast(model: "fm-timestral-5m-meter", history: ArenaFixtures.history(c),
                                request: ArenaFixtures.request(c))
        }
    }
}
