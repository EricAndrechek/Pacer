import Foundation

// The pinned Chronos weights (files and SHA-256), read by ArenaWeightStore.
extension ArenaWeightStore {
    /// `amazon/chronos-2` at the revision the arena scored
    /// (`models/fm-chronos2-meter/model.toml`). Not bundled: downloaded on
    /// first use (`ensureAvailable`). The repository has no LICENSE file; its
    /// model card (`README.md`) carries the Apache-2.0 licence, so the card
    /// travels with the weights the way Timestral's `LICENSE` does.
    static let chronosPinned: [String: [PinnedFile]] = [
        ChronosWeights.chronos2: [
            PinnedFile(name: "config.json", sha256: "ef1143bfdc9c0376d9a056eefca46cb4b1ec3d0ffacd541ff56feb40fb708031", bytes: 1067),
            PinnedFile(name: "model.safetensors", sha256: "ddcda3c7508bf2528087723e98a20707cc04b7f370ae275a9fd88078ddba4f42", bytes: 477_930_472),
            PinnedFile(name: "README.md", sha256: "c7b29bc88f5bc3ebc6e7213b6353be80090d671fefa4aa74ed20498838c16558", bytes: 7773),
        ],
    ]
}

public enum ChronosWeights {
    public static let chronos2 = "amazon/chronos-2@29ec3766d36d6f73f0696f85560a422f50e8498c"
}
