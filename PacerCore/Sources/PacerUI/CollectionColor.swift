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
/// else a color is *generated* from the recorded `seed` (frozen in
/// `ProjectMeta` — the git remote URL or path captured when the project
/// was first seen), else from the live canonical path before the seed is
/// recorded. Anchoring on the recorded seed means a folder rename, remote
/// change, or rank shuffle never recolors the project.
///
/// Projects are high-cardinality (dozens, 5+ in one donut), so a fixed
/// palette collides badly — the birthday paradox gives a same-color pair
/// among just 5 items ~70% of the time with 10 colors. Instead we generate
/// a **continuous hue** from a well-distributed hash: exact collisions
/// become essentially impossible, and rendering in OKLCH at a fixed
/// lightness + chroma keeps every hue equally vivid and legible on both
/// light and dark backgrounds. (Collections and models stay on the curated
/// `pacerColorPalette` — they're few and named, where a hand-picked
/// palette looks best.)
public func pacerProjectColor(path: String, seed: String? = nil, hex: String? = nil) -> Color {
    if let hex, let c = Color(pacerHex: hex) { return c }
    return pacerGeneratedColor(seed ?? path)
}

/// A distinct, stable, good-looking color generated from an identity
/// string. Continuous OKLCH hue from one slice of the hash, plus a
/// lightness level from an independent slice — so two identities that
/// happen to land on nearby hues still separate by value (light vs deep
/// teal), which a hue-only scheme can't. Chroma is high enough to read as
/// vivid, not muddy.
public func pacerGeneratedColor(_ seed: String) -> Color {
    let h = pacerFNV1a(seed)
    let hue = Double(h % 360)
    // Yellow/orange/green hues turn muddy (mustard, olive) at mid
    // lightness — they need to be brighter to look clean. Lift lightness
    // over that hue band; reds, blues, and purples stay richer and deeper.
    // The band is centred on OKLCH yellow (~110°) and tapers to zero by
    // ~±60°, so only the muddy hues get lifted.
    let yellowLift = 0.14 * max(0, cos((hue - 110) * .pi / 120))
    // A small value jitter from an independent hash slice separates the
    // rare pair that lands on nearby hues.
    let jitter = [-0.03, 0.0, 0.03][Int((h / 360) % 3)]
    let lightness = 0.70 + yellowLift + jitter
    return pacerOKLCH(l: lightness, c: 0.15, hueDegrees: hue)
}

/// FNV-1a 64-bit hash with a murmur-style avalanche finalizer. The
/// finalizer matters here: plain FNV-1a avalanches weakly in its low bits,
/// so sibling paths sharing a long prefix (`…/acme/api`, `…/acme/web`)
/// would land on nearby hues — exactly the projects most likely to share a
/// chart. The finalizer scrambles the bits so a one-character difference
/// scatters across the hue circle.
func pacerFNV1a(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    hash ^= hash >> 33
    hash = hash &* 0xff51_afd7_ed55_8ccd
    hash ^= hash >> 33
    hash = hash &* 0xc4ce_b9fe_1a85_ec53
    hash ^= hash >> 33
    return hash
}

/// OKLCH → sRGB `Color`. Perceptually-uniform lightness means no hue looks
/// washed out or over-dark at the same `l`, so a set of generated colors
/// reads as one cohesive family. Out-of-gamut results are clamped.
func pacerOKLCH(l: Double, c: Double, hueDegrees: Double) -> Color {
    let h = hueDegrees * .pi / 180
    let a = c * cos(h)
    let b = c * sin(h)
    // OKLab → LMS (cubed) → linear sRGB (Björn Ottosson's matrices).
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let lC = l_ * l_ * l_, mC = m_ * m_ * m_, sC = s_ * s_ * s_
    let r =  4.0767416621 * lC - 3.3077115913 * mC + 0.2309699292 * sC
    let g = -1.2684380046 * lC + 2.6097574011 * mC - 0.3413193965 * sC
    let bl = -0.0041960863 * lC - 0.7034186147 * mC + 1.7076147010 * sC
    func toSRGB(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    return Color(.sRGB, red: toSRGB(r), green: toSRGB(g), blue: toSRGB(bl))
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
