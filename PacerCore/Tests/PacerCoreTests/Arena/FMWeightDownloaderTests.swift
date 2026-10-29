import CryptoKit
import Foundation
import Testing
@testable import PacerCore

/// Weight downloads that break off (`ArenaWeightStore.Downloader`): retried on
/// a schedule, continued from where the transfer stopped, never more than one
/// at a time. A stub stands in for the network and a script for the clock;
/// nothing here touches either for real.
@Suite("Arena weights: retries and resume", .serialized)
struct FMWeightDownloaderTests {

    static let id = "acme/Tiny-1M@0123abcd"
    static let config = Data(#"{"d": 1}"#.utf8)
    static let model = Data((0..<4096).map { UInt8($0 % 251) })

    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static let pins = [
        ArenaWeightStore.PinnedFile(name: "config.json", sha256: hex(config), bytes: config.count),
        ArenaWeightStore.PinnedFile(name: "model.safetensors", sha256: hex(model), bytes: model.count),
    ]

    /// The network, scripted: each call takes the next outcome.
    final class Stub: ArenaWeightStore.Transport, @unchecked Sendable {
        enum Outcome { case fail(resume: Data?), serve(status: Int) }
        let lock = NSLock()
        var outcomes: [Outcome]
        var calls: [(file: String, resume: Data?)] = []
        let scratch: URL

        init(_ outcomes: [Outcome], scratch: URL) { self.outcomes = outcomes; self.scratch = scratch }

        func download(_ request: URLRequest, resumeData: Data?) async throws -> (URL, URLResponse) {
            let name = request.url!.lastPathComponent
            let next: Outcome = lock.withLock {
                calls.append((name, resumeData))
                return outcomes.isEmpty ? .fail(resume: nil) : outcomes.removeFirst()
            }
            switch next {
            case .fail(let resume):
                var info: [String: Any] = [NSLocalizedDescriptionKey: "The network connection was lost."]
                if let resume { info[NSURLSessionDownloadTaskResumeData] = resume }
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: info)
            case .serve(let status):
                let tmp = scratch.appendingPathComponent(UUID().uuidString)
                try (name == "config.json" ? FMWeightDownloaderTests.config : FMWeightDownloaderTests.model)
                    .write(to: tmp)
                return (tmp, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    /// Wall time that only moves when the downloader sleeps. `held` keeps a
    /// sleep from returning until the test has looked at the state before it
    /// (otherwise the scheduled retry can run before the test reads it).
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var sleeps: [TimeInterval] = []
        private var heldFlag = false
        var held: Bool {
            get { lock.lock(); defer { lock.unlock() }; return heldFlag }
            set { lock.lock(); heldFlag = newValue; lock.unlock() }
        }
        func sleep(_ s: TimeInterval) async {
            while held { try? await Task.sleep(nanoseconds: 1_000_000) }
            lock.withLock { now += s; sleeps.append(s) }
        }
        var date: Date { lock.lock(); defer { lock.unlock() }; return now }
    }

    static func scratch() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fm-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func downloader(_ stub: Stub, clock: Clock, root: URL,
                           present: @escaping @Sendable () -> Bool = { false }) -> ArenaWeightStore.Downloader {
        ArenaWeightStore.Downloader(
            transport: stub, now: { clock.date }, sleep: { await clock.sleep($0) }, root: { root },
            pins: { $0 == FMWeightDownloaderTests.id ? FMWeightDownloaderTests.pins : nil },
            isPresent: { id in
                if present() { return true }
                let dir = root.appendingPathComponent("acme/Tiny-1M@0123abcd")
                return ["config.json", "model.safetensors"].allSatisfy {
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
                }
            })
    }

    @Test func theScheduleIsAMinuteFiveThirtyThenHourly() {
        let b = (1...6).map { ArenaWeightStore.Downloader.backoff(failures: $0) }
        #expect(b == [60, 300, 1800, 3600, 3600, 3600])
        #expect(ArenaWeightStore.Downloader.backoff(failures: 0) == 0)
    }

    /// The connection drops partway through the big file; a minute later the
    /// transfer continues from its resume data, and the id lands whole.
    @Test func aDroppedTransferResumesAfterAMinute() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let resume = Data("resume-here".utf8)
        let stub = Stub([.serve(status: 200), .fail(resume: resume), .serve(status: 200), .serve(status: 206)],
                        scratch: root)
        let clock = Clock()
        clock.held = true
        let dl = Self.downloader(stub, clock: clock, root: root)
        defer { Task { await dl.stop() } }
        await dl.run([Self.id])
        // Failed once: nothing in place, a retry a minute out.
        let dir = root.appendingPathComponent("acme/Tiny-1M@0123abcd")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let pending = await dl.pendingRetries()
        #expect(pending[Self.id] == clock.date.addingTimeInterval(60))

        clock.held = false
        await dl.settle()
        #expect(clock.sleeps == [60])
        #expect(stub.calls.map(\.file) == ["config.json", "model.safetensors", "config.json", "model.safetensors"])
        // The broken file continued from where it stopped; the others started fresh.
        #expect(stub.calls[3].resume == resume)
        #expect(stub.calls[0].resume == nil && stub.calls[2].resume == nil)
        #expect(try Data(contentsOf: dir.appendingPathComponent("model.safetensors")) == Self.model)
        #expect(try Data(contentsOf: dir.appendingPathComponent("config.json")) == Self.config)
        #expect(await dl.pendingRetries().isEmpty)
        // No staging folder left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("acme").path)
        #expect(left == ["Tiny-1M@0123abcd"])
    }

    /// Every failure waits longer, up to an hour; the retries stop once the
    /// weights are there.
    @Test func failuresBackOff() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = Stub([], scratch: root)   // every call fails
        let clock = Clock()
        // The weights turn up (another copy, say) after five failed tries:
        // the next try finds them and the retries stop. Decided inside the
        // downloader's own sequence, so no timing in the test.
        let dl = Self.downloader(stub, clock: clock, root: root,
                                 present: { stub.lock.withLock { stub.calls.count >= 5 } })
        await dl.run([Self.id])
        for _ in 0..<12_000 where !(await dl.pendingRetries().isEmpty) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(clock.lock.withLock { clock.sleeps } == [60, 300, 1800, 3600, 3600])
        #expect(await dl.pendingRetries().isEmpty)
        await dl.stop()
        // One file tried per attempt (the first file fails each time).
        #expect(stub.calls.count == 5)
        #expect(stub.calls.allSatisfy { $0.file == "config.json" })
    }

    /// A wrong file is thrown away, not moved into place.
    @Test func aCorruptFileIsRefused() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        final class Corrupt: ArenaWeightStore.Transport, @unchecked Sendable {
            let scratch: URL
            init(_ s: URL) { scratch = s }
            func download(_ request: URLRequest, resumeData: Data?) async throws -> (URL, URLResponse) {
                let tmp = scratch.appendingPathComponent(UUID().uuidString)
                try Data("not the weights".utf8).write(to: tmp)
                return (tmp, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let clock = Clock()
        // A clock that never moves: the retry stays a minute away.
        let dl = ArenaWeightStore.Downloader(
            transport: Corrupt(root), now: { clock.date }, sleep: { _ in try? await Task.sleep(for: .seconds(60)) },
            root: { root }, pins: { _ in FMWeightDownloaderTests.pins }, isPresent: { _ in false })
        await dl.run([Self.id])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("acme/Tiny-1M@0123abcd").path))
        #expect(await dl.pendingRetries()[Self.id] == clock.date.addingTimeInterval(60))
        await dl.stop()
    }

    /// Hashing streams past the page cache and matches CryptoKit's one-shot.
    @Test func hashingMatches() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("big.bin")
        // Larger than one read chunk, not a multiple of it.
        let big = Data((0..<(9 << 20) + 123).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })
        try big.write(to: f)
        var pauses = 0
        #expect(try ArenaWeightStore.sha256(of: f, pause: { pauses += 1 }) == Self.hex(big))
        #expect(pauses == 3)
    }
}
