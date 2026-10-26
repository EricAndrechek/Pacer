import Foundation

// `kit/fm/backends.py` `TimesFM25Backend`: registered here, from the TimesFM
// family's own folder, once the network is ported (`"timesfm25"`).
extension FMBackends {
    /// `"timesfm25"` in `FMBackends.factories` (empty until the port lands).
    static let timesfmFactory: [String: Factory] = [:]
}
