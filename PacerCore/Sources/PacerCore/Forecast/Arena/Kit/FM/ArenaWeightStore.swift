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
    /// Mode) network, at utility priority, verified against the pinned
    /// SHA-256, then moved into place atomically. Ids without pins are
    /// skipped (nothing unpinned is ever fetched). Safe to call repeatedly
    /// and from several tasks: calls are serialized, and finished ids are
    /// skipped.
    public static func ensureAvailable(_ ids: [String]) async {
        await downloader.run(ids)
    }

    static let downloader = Downloader()

    actor Downloader {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func run(_ ids: [String]) async {
            // At most one download at a time, process-wide.
            while busy { await withCheckedContinuation { waiters.append($0) } }
            busy = true
            defer {
                busy = false
                if !waiters.isEmpty { waiters.removeFirst().resume() }
            }
            for id in ids where localURL(for: id) == nil {
                guard let files = pinned[id], let rel = relativeFolder(id), let (repo, rev) = parse(id) else {
                    Log.write("Arena", "weights \(id): not pinned, not downloaded")
                    continue
                }
                if Task.isCancelled { return }
                await Self.fetch(id: id, repo: repo, revision: rev, files: files,
                                 into: downloadRoot.appendingPathComponent(rel, isDirectory: true))
            }
        }

        private static func session() -> URLSession {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.allowsExpensiveNetworkAccess = false
            cfg.allowsConstrainedNetworkAccess = false
            cfg.waitsForConnectivity = false
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 6 * 3600
            cfg.httpMaximumConnectionsPerHost = 1
            cfg.networkServiceType = .background
            return URLSession(configuration: cfg)
        }

        /// One id: every file downloaded and verified into a staging folder,
        /// then the folder renamed into place (so `localURL` never sees half
        /// an id).
        private static func fetch(id: String, repo: String, revision: String, files: [PinnedFile], into dest: URL) async {
            let fm = FileManager.default
            let staging = dest.deletingLastPathComponent()
                .appendingPathComponent(".staging-\(dest.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
            let session = session()
            defer { session.finishTasksAndInvalidate(); try? fm.removeItem(at: staging) }
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let started = Date()
                for f in files {
                    let src = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(f.name)")!
                    var req = URLRequest(url: src)
                    req.networkServiceType = .background
                    let (tmp, response) = try await Task(priority: .utility) {
                        try await session.download(for: req)
                    }.value
                    defer { try? fm.removeItem(at: tmp) }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw ArenaError.invalid("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(f.name)")
                    }
                    let digest = try await Task(priority: .utility) { try sha256(of: tmp) }.value
                    guard digest == f.sha256 else {
                        throw ArenaError.invalid("\(f.name): sha256 \(digest) is not the pinned \(f.sha256)")
                    }
                    try fm.moveItem(at: tmp, to: staging.appendingPathComponent(f.name))
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: staging, to: dest)
                Log.write("Arena", "weights \(id): downloaded and verified in \(Int(Date().timeIntervalSince(started))) s")
            } catch {
                Log.write("Arena", "weights \(id): download failed (\(error)); will retry later")
            }
        }
    }

    /// SHA-256 of a file, streamed (the 209M network is 837 MB).
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
