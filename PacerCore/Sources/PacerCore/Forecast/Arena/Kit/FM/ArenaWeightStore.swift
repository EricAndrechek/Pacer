import CryptoKit
import Foundation

/// Where pretrained forecaster weights live on this Mac, and how missing ones
/// arrive (`kit/fm/weights.py`'s job, for the app).
///
/// A weights id is `"<org>/<name>@<revision>"` (`"mistralai/Timestral-5M@bdd2…"`),
/// the string a model's `model.toml` pins and its `ArenaModelSpec.weights`
/// lists. Its local form is a folder holding `model.safetensors` and
/// `config.json` (and the licence the weights ship under), found, in order:
///
/// 1. in the app bundle, `Contents/Resources/ForecastWeights/<org>/<name>@<rev>/`
///    (the 5M and 28M networks ship with Pacer: `make fetch-weights`);
/// 2. in `~/Library/Application Support/Pacer/ForecastWeights/<org>/<name>@<rev>/`
///    (the larger ones, downloaded by `ensureAvailable`).
///
/// Every file is pinned by SHA-256: a download that does not match is thrown
/// away, so a model only ever runs on the exact weights the arena scored.
public enum ArenaWeightStore {
    public struct PinnedFile: Sendable {
        public let name: String
        public let sha256: String
        public let bytes: Int
    }

    /// The Mistral AI weights licence (Modified MIT), identical at every
    /// pinned revision: shipped beside the weights, as it requires.
    static let licence = PinnedFile(name: "LICENSE",
                                    sha256: "648194727930df730890e9f9affdbcc5c930d406d6829559b25ca3d5a973fc8c", bytes: 1695)

    /// Every weights id a registered model may name, with its files' hashes:
    /// each network family pins its own (`timestralPinned` here, the others
    /// in their own folders), so adding a family never edits another's table.
    public static let pinned: [String: [PinnedFile]] = timestralPinned
        .merging(timesfmPinned) { a, _ in a }
        .merging(chronosPinned) { a, _ in a }

    static let timestralPinned: [String: [PinnedFile]] = [
        "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f": [
            PinnedFile(name: "config.json", sha256: "b5f27f61513f8fd1a3aa996f3720d3679cb40bce5bcb08eb3dc320ce726e7c2f", bytes: 904),
            PinnedFile(name: "model.safetensors", sha256: "7ace108c4987e7f2a99a75a445240019d1d31c2117139d1bd05ffdfd25aca738", bytes: 20_843_960),
            licence,
        ],
        "mistralai/Timestral-28M@49b26409ac87b5935539a5d8ffe7f397b720db47": [
            PinnedFile(name: "config.json", sha256: "0cdf44b8ea981191de53078e0a5ecbbd437046bd939a546d5dbe17868f71281f", bytes: 961),
            PinnedFile(name: "model.safetensors", sha256: "dfc83c6220937ce5fc6687b35a4df94cd25e28a2cfe6fb92a23dad6301b2015d", bytes: 111_296_464),
            licence,
        ],
        "mistralai/Timestral-123M@5a147287addda85f6acd8da3fb8858fe9af7e8f7": [
            PinnedFile(name: "config.json", sha256: "7bb4c042fb2d2ed6469b6758ba380dfeda3ab32df47690a87aec1527bdae79bf", bytes: 1074),
            PinnedFile(name: "model.safetensors", sha256: "599fafa73cadbbc800b5a346ca900fa741ee3e5fd22e3b4a4430e151e74f4bc2", bytes: 490_445_904),
            licence,
        ],
        "mistralai/Timestral-209M@9874d252ab0aae16f7f7c999f98f98d6ad7d8365": [
            PinnedFile(name: "config.json", sha256: "1764139bb6d37ee5ff543f470495c086cfa6c373f7134fc61c7e3d844538bfd8", bytes: 1130),
            PinnedFile(name: "model.safetensors", sha256: "1456effb9927e3daa8c7234f10497e3424233869245a9c72b8ecebaf7ad2b7fa", bytes: 837_271_648),
            licence,
        ],
    ]

    /// The files a network needs to load (the licence travels with them but
    /// is not required to run).
    static let required = ["config.json", "model.safetensors"]

    /// `"org/name@rev"` → `("org/name", "rev")`; nil when not that shape.
    public static func parse(_ id: String) -> (repo: String, revision: String)? {
        let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].split(separator: "/").count == 2, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// `<org>/<name>@<rev>`, relative to a ForecastWeights root.
    static func relativeFolder(_ id: String) -> String? {
        guard let (repo, rev) = parse(id) else { return nil }
        return "\(repo)@\(rev)"
    }

    /// `~/Library/Application Support/Pacer/ForecastWeights` (the same
    /// `Pacer` folder the command-line tool's link lives in).
    public static var downloadRoot: URL {
        if let o = downloadRootOverride { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Pacer/ForecastWeights", isDirectory: true)
    }

    /// Tests only: download somewhere other than Application Support.
    nonisolated(unsafe) static var downloadRootOverride: URL?

    /// The app bundle's `Resources/ForecastWeights` (nil in tests and tools).
    public static var bundledRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ForecastWeights", isDirectory: true)
    }

    /// The folder holding `model.safetensors` + `config.json` for `id`: the
    /// app bundle's copy first, then a download. Nil when neither is
    /// complete. Never downloads, never hashes (a download is verified
    /// before it is moved into place; a bundled copy at build time).
    public static func localURL(for id: String) -> URL? {
        guard let rel = relativeFolder(id) else { return nil }
        for root in [bundledRoot, downloadRoot].compactMap({ $0 }) {
            let dir = root.appendingPathComponent(rel, isDirectory: true)
            if required.allSatisfy({ isComplete(dir.appendingPathComponent($0), id: id) }) { return dir }
        }
        return nil
    }

    /// A file is there and has its pinned size (a cheap check that catches a
    /// truncated copy without hashing hundreds of megabytes on every lookup).
    static func isComplete(_ url: URL, id: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return false }
        guard let pin = pinned[id]?.first(where: { $0.name == url.lastPathComponent }) else { return size > 0 }
        return size == pin.bytes
    }

    /// `ArenaServices.weights` for the app: the local folder, never a download.
    public static let services: @Sendable (String) -> URL? = { localURL(for: $0) }

    // MARK: - Downloads

    /// Downloads every id in `ids` that is not on this Mac yet, one file at a
    /// time, from `https://huggingface.co/<repo>/resolve/<revision>/<file>`:
    /// never over an expensive (cellular, hotspot) or constrained (Low Data
    /// Mode) network, at background priority, verified against the pinned
    /// SHA-256, then moved into place atomically. Ids without pins are
    /// skipped (nothing unpinned is ever fetched). Safe to call repeatedly
    /// and from several tasks: calls are serialized, finished ids are
    /// skipped, and an id that failed is retried on its own schedule
    /// (`Downloader.backoff`), resuming where the transfer broke off.
    public static func ensureAvailable(_ ids: [String]) async {
        await downloader.run(ids)
    }

    static let downloader = Downloader(transport: URLSessionWeightTransport())

    /// The network half of a download, so tests can stand in for it.
    protocol Transport: Sendable {
        /// `request`'s body in a temporary file the caller then owns,
        /// continuing an earlier transfer when `resumeData` is given. A
        /// failure that can be continued throws an `NSError` carrying
        /// `NSURLSessionDownloadTaskResumeData`, as `URLSession` does.
        func download(_ request: URLRequest, resumeData: Data?) async throws -> (URL, URLResponse)
    }

    struct URLSessionWeightTransport: Transport {
        /// One session for the process, never invalidated: the partial file
        /// a resume continues belongs to it.
        private static let session: URLSession = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.allowsExpensiveNetworkAccess = false
            cfg.allowsConstrainedNetworkAccess = false
            cfg.waitsForConnectivity = false
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 6 * 3600
            cfg.httpMaximumConnectionsPerHost = 1
            cfg.networkServiceType = .background
            return URLSession(configuration: cfg)
        }()

        func download(_ request: URLRequest, resumeData: Data?) async throws -> (URL, URLResponse) {
            if let resumeData { return try await Self.session.download(resumeFrom: resumeData) }
            return try await Self.session.download(for: request)
        }
    }

    actor Downloader {
        /// After the first failure an id waits a minute, then five, then
        /// thirty, then an hour between tries for as long as the process
        /// runs. A connection that drops mid-file is the usual failure (a
        /// laptop changing networks), and the next try resumes it.
        static let backoffSchedule: [TimeInterval] = [60, 5 * 60, 30 * 60]
        static let backoffCeiling: TimeInterval = 3600

        static func backoff(failures: Int) -> TimeInterval {
            guard failures > 0 else { return 0 }
            return failures <= backoffSchedule.count ? backoffSchedule[failures - 1] : backoffCeiling
        }

        private struct Failure { var count: Int; var retryAt: Date }

        private let transport: any Transport
        private let now: @Sendable () -> Date
        private let sleep: @Sendable (TimeInterval) async -> Void
        private let root: @Sendable () -> URL
        private let pins: @Sendable (String) -> [PinnedFile]?
        private let isPresent: @Sendable (String) -> Bool
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var failures: [String: Failure] = [:]
        /// Where a broken transfer can continue from, by `id|file`.
        private var resumeData: [String: Data] = [:]
        private var retry: Task<Void, Never>?
        private var stopped = false

        init(transport: any Transport,
             now: @escaping @Sendable () -> Date = { Date() },
             sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
             root: @escaping @Sendable () -> URL = { ArenaWeightStore.downloadRoot },
             pins: @escaping @Sendable (String) -> [PinnedFile]? = { ArenaWeightStore.pinned[$0] },
             isPresent: @escaping @Sendable (String) -> Bool = { ArenaWeightStore.localURL(for: $0) != nil }) {
            self.transport = transport; self.now = now; self.sleep = sleep; self.root = root
            self.pins = pins; self.isPresent = isPresent
        }

        /// The ids that failed and are waiting for their next try, with when
        /// (tests, the log).
        func pendingRetries() -> [String: Date] { failures.mapValues(\.retryAt) }

        /// Wait for the scheduled retry to finish (tests).
        func settle() async { await retry?.value }

        /// No more retries (tests: a scripted clock would otherwise retry
        /// forever).
        func stop() {
            stopped = true
            retry?.cancel()
            retry = nil
        }

        func run(_ ids: [String]) async {
            // At most one download at a time, process-wide.
            while busy { await withCheckedContinuation { waiters.append($0) } }
            busy = true
            defer {
                busy = false
                if !waiters.isEmpty { waiters.removeFirst().resume() }
            }
            // Arrived some other way (a later build bundles it): stop retrying.
            for id in ids where isPresent(id) { failures[id] = nil }
            for id in ids where !isPresent(id) {
                guard let files = pins(id), let rel = relativeFolder(id), let (repo, rev) = parse(id) else {
                    Log.write("Arena", "weights \(id): not pinned, not downloaded")
                    continue
                }
                // Not yet: its retry is scheduled.
                if let f = failures[id], f.retryAt > now() { continue }
                if Task.isCancelled || stopped { return }
                do {
                    try await fetch(id: id, repo: repo, revision: rev, files: files,
                                    into: root().appendingPathComponent(rel, isDirectory: true))
                    failures[id] = nil
                } catch {
                    let count = (failures[id]?.count ?? 0) + 1
                    let wait = Self.backoff(failures: count)
                    failures[id] = Failure(count: count, retryAt: now().addingTimeInterval(wait))
                    Log.write("Arena", "weights \(id): download failed (\(Self.describe(error))); "
                              + "retrying in \(Int(wait / 60)) min")
                }
            }
            scheduleRetry()
        }

        /// One task, sleeping until the earliest failed id is due, then
        /// running every due one again; it schedules the next itself.
        private func scheduleRetry() {
            guard !stopped, retry == nil, let next = failures.values.map(\.retryAt).min() else { return }
            let wait = max(0, next.timeIntervalSince(now()))
            retry = Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                await self.sleep(wait)
                await self.retryDue()
            }
        }

        private func retryDue() async {
            retry = nil
            guard !stopped else { return }
            let due = failures.filter { $0.value.retryAt <= now() }.map(\.key).sorted()
            if due.isEmpty { scheduleRetry() } else { await run(due) }
        }

        /// One id: every file downloaded and verified into a staging folder,
        /// then the folder renamed into place (so `localURL` never sees half
        /// an id).
        private func fetch(id: String, repo: String, revision: String, files: [PinnedFile], into dest: URL) async throws {
            let fm = FileManager.default
            let staging = dest.deletingLastPathComponent()
                .appendingPathComponent(".staging-\(dest.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let started = now()
            for f in files {
                let src = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(f.name)")!
                var req = URLRequest(url: src)
                req.networkServiceType = .background
                let key = "\(id)|\(f.name)"
                let resume = resumeData.removeValue(forKey: key)
                let tmp: URL, response: URLResponse
                do {
                    let transport = self.transport, request = req
                    (tmp, response) = try await Task.detached(priority: .background) {
                        try await transport.download(request, resumeData: resume)
                    }.value
                } catch {
                    // Kept for the next try; a resume that itself fails
                    // without new data starts that file over.
                    if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        resumeData[key] = data
                    }
                    throw error
                }
                defer { try? fm.removeItem(at: tmp) }
                // 206: the rest of a resumed transfer, already joined to its
                // first part in `tmp`.
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
                    throw ArenaError.invalid("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(f.name)")
                }
                let digest = try await Task.detached(priority: .background) { try sha256(of: tmp) }.value
                guard digest == f.sha256 else {
                    throw ArenaError.invalid("\(f.name): sha256 \(digest) is not the pinned \(f.sha256)")
                }
                try fm.moveItem(at: tmp, to: staging.appendingPathComponent(f.name))
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: staging, to: dest)
            Log.write("Arena", "weights \(id): downloaded and verified in \(Int(now().timeIntervalSince(started))) s")
        }

        /// An error for the log without its resume blob.
        static func describe(_ error: Error) -> String {
            let e = error as NSError
            guard e.domain == NSURLErrorDomain else { return "\(error)" }
            let resumable = e.userInfo[NSURLSessionDownloadTaskResumeData] != nil
            return "\(e.domain) \(e.code) \"\(e.localizedDescription)\"" + (resumable ? ", resumable" : "")
        }
    }

    /// SHA-256 of a file, streamed (the 209M network is 837 MB): read past
    /// the page cache (`F_NOCACHE`), so verifying a download does not push
    /// the store and the app's own pages out of memory on a Mac short of it,
    /// four megabytes at a time with a breath between, at whatever priority
    /// the caller runs (the downloader: background).
    static func sha256(of url: URL, pause: () -> Void = { usleep(2_000) }) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let size = 4 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16_384)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        while true {
            let n = read(fd, buffer.baseAddress, size)
            if n < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            pause()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
