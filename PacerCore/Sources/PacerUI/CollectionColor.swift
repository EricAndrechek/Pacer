import SwiftUI
import AppKit

/// The curated swatch palette offered in color pickers and used as the
/// auto-assigned fallback. Order is stable, so a hash-derived index gives
/// a stable color across launches.
public let pacerColorPalette: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .cyan,
]

/// Stable identity hue for a collection. Uses the explicit `hex` when the
/// user picked one, else hashes `seed` (the collection's name at creation)
/// into the palette — `Hasher` is per-process randomized, so we can't use
/// it for a color that must survive relaunch.
public func pacerCollectionColor(seed: String, hex: String? = nil) -> Color {
    if let hex, let c = Color(pacerHex: hex) { return c }
    return pacerHashedColor(seed)
}

/// Stable color for a project. Precedence: an explicit user `hex` wins;
/// else the recorded `seed` (frozen in `ProjectMeta` — the git remote URL
/// or path captured when the project was first seen) is hashed; else the
/// live canonical path is hashed as a fallback before the seed is
/// recorded. Anchoring on the recorded seed means a later folder rename,
/// remote change, or rank shuffle never recolors the project.
public func pacerProjectColor(path: String, seed: String? = nil, hex: String? = nil) -> Color {
    if let hex, let c = Color(pacerHex: hex) { return c }
    return pacerHashedColor(seed ?? path)
}

/// Stable color for an LLM model. Model names are already stable, so no DB
/// record is needed — just hash the short name so every model donut,
/// legend, and swatch across the app agrees (they used to use three
/// different color systems). Keyed on `pacerShortModel` so provider
/// prefixes don't split a model into two colors.
public func pacerModelColor(_ model: String) -> Color {
    pacerHashedColor(pacerShortModel(model))
}

/// Sum-of-unicode-scalars → palette index. The same recipe as the
/// per-model swatches; deterministic across processes.
func pacerHashedColor(_ seed: String) -> Color {
    guard !seed.isEmpty else { return pacerColorPalette[0] }
    let sum = seed.unicodeScalars.reduce(UInt32(0)) { $0 &+ UInt32($1.value) }
    return pacerColorPalette[Int(sum % UInt32(pacerColorPalette.count))]
}

public extension Color {
    /// Parse `#RRGGBB` (or `RRGGBB`). Returns nil on malformed input.
    init?(pacerHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

/// Serialize a SwiftUI `Color` to `#RRGGBB` (sRGB) for persistence.
public func pacerHexString(from color: Color) -> String? {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
}
