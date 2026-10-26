import Foundation

// `kit/fm/backends.py` `Chronos2Backend`: registered here, from the Chronos
// family's own folder, once the network is ported (`"chronos2"`).
extension FMBackends {
    /// `"chronos2"` in `FMBackends.factories` (empty until the port lands).
    static let chronosFactory: [String: Factory] = [:]
}
