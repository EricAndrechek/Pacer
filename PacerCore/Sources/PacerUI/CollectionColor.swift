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
/// light and dark backgrounds. (Collections and models stay on the curated
/// `pacerColorPalette` — they're few and named, where a hand-picked
/// palette looks best.)
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
/// system palette it was sampled from.
private func pacerRidge(_ hue: Double) -> (l: Double, c: Double) {
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

/// Stable color for an LLM model. Model names are already stable, so no DB
/// record is needed — just generate from the short name so every model
/// donut, legend, and swatch across the app agrees (they used to use three
/// different color systems). Keyed on `pacerShortModel` so provider
/// prefixes don't split a model into two colors. Uses the same pretty ridge
/// as projects: the old sum-of-scalars hash into a 10-color palette collided
/// badly (birthday paradox: ~70% chance two of five models shared a color).
public func pacerModelColor(_ model: String) -> Color {
    pacerGeneratedColor(pacerShortModel(model))
}

// MARK: - Guaranteed-distinct colors for one chart

/// Assign visually-distinct colors to a set of identities shown together in
/// a single chart (a donut's slices + its legend). Each identity starts at
/// its stable color — the `hex` override if set, else the generated ridge
/// color — and any pair closer than `minDelta` in OKLab (i.e. that would
/// read as "the same color") is separated by rotating the lower-priority
/// identity's hue along the bright ridge until it clears.
///
/// A pure hash-per-seed can't promise this: a gold (~85°) and a chartreuse
/// (~125°) are only ΔE≈0.15 apart yet both read as "yellow", so they need
/// *active* separation. Priority is a stable sort (hex overrides first as
/// immovable anchors, then by seed), so the result depends only on *which*
/// identities are present — colors stay put across value re-sorts and shift
/// only when the visible set itself changes. Returns colors in input order.
public func pacerDistinctColors(
    _ items: [(seed: String, hex: String?)],
    minDelta: Double = 0.17
) -> [Color] {
    let n = items.count
    guard n > 0 else { return [] }
    var result = [Color?](repeating: nil, count: n)
    var placed: [(Double, Double, Double)] = []

    let order = (0..<n).sorted { a, b in
        let ha = items[a].hex != nil, hb = items[b].hex != nil
        if ha != hb { return ha }                 // hex overrides placed first
        return items[a].seed < items[b].seed
    }
    func minDist(_ lab: (Double, Double, Double)) -> Double {
        placed.map { pacerLabDistance($0, lab) }.min() ?? .infinity
    }

    for i in order {
        // Hex override: an immovable anchor that still repels generated colors.
        if let hex = items[i].hex, let c = Color(pacerHex: hex) {
            placed.append(pacerLabFromColor(c)); result[i] = c; continue
        }
        let g = pacerGeneratedComponents(items[i].seed)
        let baseLab = pacerLabFromLCH(l: g.l, c: g.c, hue: g.hue)
        if minDist(baseLab) >= minDelta {
            placed.append(baseLab)
            result[i] = pacerOKLCH(l: g.l, c: g.c, hueDegrees: g.hue)
            continue
        }
        // Rotate along the *bright* ridge (lift 0 — never darken into mud),
        // small alternating steps so the nudge stays minimal. Keep the best
        // separation seen as a fallback for a crowded wheel.
        var chosen: (lab: (Double, Double, Double), color: Color)?
        var best: (dist: Double, lab: (Double, Double, Double), color: Color)?
        rotate: for step in 1...30 {
            for sign in [1.0, -1.0] {
                var hue = (g.hue + sign * Double(step) * 12).truncatingRemainder(dividingBy: 360)
                if hue < 0 { hue += 360 }
                let (l, c) = pacerRidge(hue)
                let lab = pacerLabFromLCH(l: l, c: c, hue: hue)
                let color = pacerOKLCH(l: l, c: c, hueDegrees: hue)
                let d = minDist(lab)
                if d >= minDelta { chosen = (lab, color); break rotate }
                if best == nil || d > best!.dist { best = (d, lab, color) }
            }
        }
        let pick = chosen ?? best.map { ($0.lab, $0.color) }
            ?? (baseLab, pacerOKLCH(l: g.l, c: g.c, hueDegrees: g.hue))
        placed.append(pick.0); result[i] = pick.1
    }
    return result.map { $0 ?? .gray }
}

/// OKLab (l, a, b) for an OKLCH triple — the space perceptual distance is
/// measured in.
private func pacerLabFromLCH(l: Double, c: Double, hue: Double) -> (Double, Double, Double) {
    let h = hue * .pi / 180
    return (l, c * cos(h), c * sin(h))
}

/// OKLab (l, a, b) for an arbitrary `Color` (used for hex overrides, which
/// aren't generated from a ridge hue). sRGB → linear → OKLab.
private func pacerLabFromColor(_ color: Color) -> (Double, Double, Double) {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
    func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let R = lin(Double(ns.redComponent)), G = lin(Double(ns.greenComponent)), B = lin(Double(ns.blueComponent))
    let l = 0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B
    let m = 0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B
    let s = 0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B
    let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
    return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
}

private func pacerLabDistance(_ x: (Double, Double, Double), _ y: (Double, Double, Double)) -> Double {
    let dl = x.0 - y.0, da = x.1 - y.1, db = x.2 - y.2
    return (dl * dl + da * da + db * db).squareRoot()
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
