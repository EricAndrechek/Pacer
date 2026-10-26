import Foundation

// The pinned TimesFM weights (files and SHA-256), read by ArenaWeightStore.
extension ArenaWeightStore {
    /// `google/timesfm-2.5-200m-pytorch` at the revision the arena scored.
    /// Apache-2.0: the repository carries no LICENSE file, its model card
    /// (`README.md`, `license: apache-2.0`) says so, and that card is what
    /// travels beside the weights here. Never bundled with the app: it is
    /// downloaded on first use (`ensureAvailable`).
    static let timesfmPinned: [String: [PinnedFile]] = [
        FMWeights.timesfm25: [
            PinnedFile(name: "config.json", sha256: "cd3315b760d5cc7e278d7afdf41b897031ced888fc6c115bd9b3ac0ea2c47408", bytes: 475),
            PinnedFile(name: "model.safetensors", sha256: "2f776efe6245e42b24bc4153ffdf61810140210e4bd3b01fb21f7aa779ab6ce8", bytes: 925_181_104),
            PinnedFile(name: "README.md", sha256: "4c3f16633a3d8b9324904bf004429aced2ee009b84e64effb59a902520cc7f2e", bytes: 2496),
        ],
    ]
}

extension FMWeights {
    public static let timesfm25 = "google/timesfm-2.5-200m-pytorch@1d952420fba87f3c6dee4f240de0f1a0fbc790e3"
}
