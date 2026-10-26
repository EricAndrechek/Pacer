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

/// `ensureAvailable` for real: the 5M network (21 MB) from Hugging Face into
/// a temporary folder, verified and moved into place, then found by
/// `localURL` and loaded. Opt-in (`PACER_WEIGHTS_DOWNLOAD_TEST=1`): it needs
/// the network, which CI and ordinary runs should not.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PACER_WEIGHTS_DOWNLOAD_TEST"] != nil))
struct FMWeightsDownloadTests {
    @Test func downloadsVerifiesAndLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-weights-\(UUID().uuidString)")
        ArenaWeightStore.downloadRootOverride = root
        defer { ArenaWeightStore.downloadRootOverride = nil; try? FileManager.default.removeItem(at: root) }
        let id = FMWeights.timestral5M
        #expect(ArenaWeightStore.localURL(for: id) == nil || ArenaWeightStore.bundledRoot != nil)
        await ArenaWeightStore.ensureAvailable([id, "mistralai/Unpinned@0"])
        let dir = try #require(ArenaWeightStore.localURL(for: id))
        #expect(dir.path.hasPrefix(root.path))
        for f in ArenaWeightStore.pinned[id]! {
            #expect(try ArenaWeightStore.sha256(of: dir.appendingPathComponent(f.name)) == f.sha256)
        }
        #expect(try TimestralNetwork(directory: dir).parameterCount == 5_208_960)
        // Nothing left half-done beside it.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
        #expect(!leftovers.contains { $0.hasPrefix(".staging") })
        // Already there: a second call does nothing.
        await ArenaWeightStore.ensureAvailable([id])
    }
}

@Suite struct SafeTensorsTests {
    @Test func halfPrecisionWidensExactly() {
        let cases: [(UInt16, Float)] = [(0x3c00, 1), (0xc000, -2), (0x0000, 0), (0x7bff, 65504), (0x0001, 0x1p-24),
                                        (0x03ff, 1023 * 0x1p-24), (0x0400, 0x1p-14), (0x3555, 0.33325195), (0x7c00, .infinity)]
        for (h, f) in cases { #expect(SafeTensors.halfToFloat(h) == f, "\(String(h, radix: 16))") }
        #expect(SafeTensors.halfToFloat(0x7e00).isNaN)
        #expect(SafeTensors.halfToFloat(0x8000).sign == .minus)
    }

    /// A file written here (F32, F16 and BF16 tensors) reads back.
    @Test func readsEachDtype() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString).safetensors")
        defer { try? FileManager.default.removeItem(at: url) }
        var body = Data()
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let f32: [Float] = [1.5, -2, 3.25]
        for x in f32 { body += le(x.bitPattern) }
        for h: UInt16 in [0x3c00, 0xc000] { body += le(h) }            // 1, -2 as F16
        for b: UInt16 in [0x3fc0, 0xc040] { body += le(b) }            // 1.5, -3 as BF16
        let header = #"{"a":{"dtype":"F32","shape":[3],"data_offsets":[0,12]},"b":{"dtype":"F16","shape":[2],"data_offsets":[12,16]},"c":{"dtype":"BF16","shape":[2],"data_offsets":[16,20]},"__metadata__":{"format":"pt"}}"#
        var h = Data(header.utf8)
        while (8 + h.count) % 8 != 0 { h.append(0x20) }
        try (le(UInt64(h.count)) + h + body).write(to: url)
        let st = try SafeTensors(url: url)
        let a = try st.floats("a", shape: [3]), b = try st.floats("b"), c = try st.floats("c")
        #expect((0..<3).map { a[$0] } == f32)
        #expect([b[0], b[1]] == [1, -2])
        #expect([c[0], c[1]] == [1.5, -3])
        #expect(throws: SafeTensors.ReadError.self) { try st.floats("a", shape: [4]) }
        #expect(throws: SafeTensors.ReadError.self) { try st.floats("missing") }
    }
}
