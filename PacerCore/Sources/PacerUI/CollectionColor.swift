import SwiftUI

/// Stable identity hue for a project collection.
///
/// Mirrors the per-model swatch recipe (sum of unicode scalars modulo a
/// fixed palette) rather than `Color(hash)` because Swift's `Hasher` is
/// per-process randomized — it would recolor every collection on each
/// launch. Seeded by the collection's `colorSeed` (its name at creation
/// time), so a later rename keeps the color stable. There is no
/// per-project color in Pacer for this to collide with.
public func pacerCollectionColor(seed: String) -> Color {
    let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .cyan,
    ]
    guard !seed.isEmpty else { return palette[0] }
    let scalarSum = seed.unicodeScalars.reduce(UInt32(0)) { $0 &+ UInt32($1.value) }
    return palette[Int(scalarSum % UInt32(palette.count))]
}
