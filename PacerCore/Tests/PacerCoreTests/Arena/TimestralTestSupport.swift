import Foundation
@testable import PacerCore

/// Where the tests find Timestral weights: the store's places first (the
/// app's bundled copy, then Application Support), then a local Hugging Face
/// cache (`~/.cache/huggingface/hub`, where the arena's Python keeps them).
/// Tests that need a network skip when none of these holds it.
enum TimestralTestWeights {
    static let ids: [String: String] = [
        "5m": "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f",
        "28m": "mistralai/Timestral-28M@49b26409ac87b5935539a5d8ffe7f397b720db47",
        "123m": "mistralai/Timestral-123M@5a147287addda85f6acd8da3fb8858fe9af7e8f7",
        "209m": "mistralai/Timestral-209M@9874d252ab0aae16f7f7c999f98f98d6ad7d8365",
    ]

    static func url(_ id: String) -> URL? {
        if let u = ArenaWeightStore.localURL(for: id) { return u }
        guard let (repo, rev) = ArenaWeightStore.parse(id) else { return nil }
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let snap = home.appendingPathComponent(".cache/huggingface/hub/models--\(parts[0])--\(parts[1])/snapshots/\(rev)")
        let ok = FileManager.default.fileExists(atPath: snap.appendingPathComponent("model.safetensors").path)
            && FileManager.default.fileExists(atPath: snap.appendingPathComponent("config.json").path)
        return ok ? snap : nil
    }

    static func services() -> ArenaServices { ArenaServices(weights: { url($0) }) }

    static func forecaster(_ size: String) throws -> TimestralForecaster? {
        guard let id = ids[size], let u = url(id) else { return nil }
        return try FMBackends.timestral(id, directory: u)
    }
}
