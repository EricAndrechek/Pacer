import SwiftUI
import AppKit

/// The curated swatch grid offered in the collection color picker (a hand
/// override the user can pick, stored as `colorHex`). Order is stable.
/// Auto-assigned colors don't come from here — they're *generated* on the
/// pretty ridge (`pacerGeneratedColor`), so they never collide.
public let pacerColorPalette: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .cyan,
]

/// Stable identity color for a collection. Uses the explicit `hex` when the
/// user picked one, else *generates* a color from `seed` (the collection's
/// name at creation) — `Hasher` is per-process randomized, so we can't use
/// it for a color that must survive relaunch.
public func pacerCollectionColor(seed: String, hex: String? = nil) -> Color {
    if let hex, let c = Color(pacerHex: hex) { return c }
    return pacerGeneratedColor(seed)
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
/// light and dark backgrounds. (Collections offer the curated
/// `pacerColorPalette` as a hand override; models get a curated
/// family-hue scheme — see `pacerModelColor` — because their ids are
/// globally stable and worth naming.)
public func pacerProjectColor(path: String, seed: String? = nil, hex: String? = nil) -> Color {
    if let hex, let c = Color(pacerHex: hex) { return c }
    return pacerGeneratedColor(seed ?? path)
}

/// Anchor points sampled from Apple's macOS system colors converted to
/// OKLCH — the palette Pacer's model swatches always used and that reads as
/// "pretty". Pretty colors don't live on a flat lightness/chroma plane:
/// reds, blues, and purples are deep and saturated (L≈0.6, C≈0.22), yellow
/// is light (L≈0.87), and the teals are soft (C≈0.11). A flat plane washes
/// out the deep hues and muddies the light ones. Sorted by hue so
/// `pacerRidge` can interpolate between them.
private let pacerColorRidge: [(h: Double, l: Double, c: Double)] = [
    (17.9, 0.650, 0.238),  // pink
    (28.7, 0.654, 0.232),  // red
    (62.6, 0.765, 0.175),  // orange
    (90.4, 0.865, 0.177),  // yellow
    (147.4, 0.730, 0.194), // green
    (189.0, 0.748, 0.130), // mint
    (212.7, 0.700, 0.111), // teal
    (233.9, 0.707, 0.133), // cyan
    (257.4, 0.603, 0.218), // blue
    (278.3, 0.529, 0.191), // indigo
    (312.4, 0.615, 0.213), // purple
]

/// Interpolated (lightness, chroma) on the pretty ridge for any hue, with
/// smoothstep easing and wraparound across the purple→pink gap. This is
/// what lets a *continuous* generated hue look as good as the discrete
/// system palette it was sampled from. Internal so `PacerModelPalette` can
/// seat its placed hues on the same ridge.
func pacerRidge(_ hue: Double) -> (l: Double, c: Double) {
    let n = pacerColorRidge.count
    let hue = hue.truncatingRemainder(dividingBy: 360)
    for i in 0..<n {
        let a = pacerColorRidge[i], b = pacerColorRidge[(i + 1) % n]
        var span = (b.h - a.h).truncatingRemainder(dividingBy: 360)
        if span < 0 { span += 360 }
        var off = (hue - a.h).truncatingRemainder(dividingBy: 360)
        if off < 0 { off += 360 }
        if off <= span || i == n - 1 {
            if span == 0 { span = 360 }
            let raw = off / span
            let t = raw * raw * (3 - 2 * raw) // smoothstep
            return (a.l + (b.l - a.l) * t, a.c + (b.c - a.c) * t)
        }
    }
    return (0.70, 0.15)
}

/// A distinct, stable, good-looking color generated from an identity
/// string. The hash picks a continuous hue; lightness and chroma come from
/// the pretty ridge at that hue, so every generated color has the vividness
/// of Apple's system palette and exact collisions are essentially
/// impossible. An independent hash slice adds a light/deep jitter so two
/// identities that land on nearby hues still separate (light vs deep teal).
public func pacerGeneratedColor(_ seed: String) -> Color {
    let g = pacerGeneratedComponents(seed)
    return pacerOKLCH(l: g.l, c: g.c, hueDegrees: g.hue)
}

/// The pre-de-collision OKLCH components for a generated seed. Continuous
/// hue from the hash; lightness+chroma from the pretty ridge; a hue-safe
/// light/deep jitter from an independent hash slice. Returned as parts so
/// both the `Color` and its OKLab coordinates (for perceptual-distance
/// checks in `pacerDistinctColors`) come from one place.
private func pacerGeneratedComponents(_ seed: String) -> (hue: Double, l: Double, c: Double) {
    let h = pacerFNV1a(seed)
    let hue = Double(h % 360)
    let (l, c) = pacerRidge(hue)
    var lift = [-0.055, 0.0, 0.055][Int((h / 360) % 3)]
    // Never *darken* the already-light yellow band — that re-introduces the
    // mustard/olive mud a flat scheme suffers from. Lightening is always safe.
    if l > 0.76 && lift < 0 { lift = 0 }
    return (hue, l + lift, c)
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

/// Stable, curated color for an LLM model — the model-color entry point used
/// across every donut, legend, chart, and swatch. Delegates to the active
/// `PacerModelPalette` (see `ModelPalette.swift`), which spreads models along
/// an ordered spectrum: four intelligence classes ~90° apart on the wheel,
/// each family's versions building toward the next tier, with clear jumps
/// between major versions. Unrecognized families fall back to the generated
/// (hashed) color, so nothing ever renders colorless.
///
/// Symmetric: the raw `claude-opus-4-7` and its display form `Opus 4.7`
/// resolve to the same color, so callers can pass whichever they have.
public func pacerModelColor(_ model: String) -> Color {
    pacerModelPalette.color(for: model)
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
