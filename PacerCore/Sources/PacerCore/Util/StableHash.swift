import Foundation

/// FNV-1a 64-bit: tiny, dependency-free, and the same in every process,
/// unlike `Hasher`, which is seeded per launch. For identifiers that are
/// stored or compared across runs.
enum StableHash {
    static func fnv1a64(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    static func fnv1a64(_ s: String) -> UInt64 { fnv1a64(s.utf8) }
}
