import Foundation
import SwiftUI

/// The curated catalog of Claude models Pacer knows about, per family, sorted
/// oldest → newest. It exists so **colors are the same for every user**: the
/// spacing is derived from this shared list, not from any one person's usage.
///
/// Regenerate/extend it from the pricing catalog on each release (the parser
/// in `PacerModelIdentity` + a clean pass — keep major 3–12, minor 0–9,
/// normalize `4.0`≡`4`, drop provider junk like `opus-41`-as-major and
/// region-leaks — produces exactly these canonical `(major, minor)` pairs).
/// A model that isn't listed still renders a sensible in-family color via the
/// fallback in `PacerModelPalette`, so a just-shipped version is never broken.
public let pacerModelCatalog: [PacerModelIdentity.Family: [(major: Int, minor: Int)]] = [
    .haiku:  [(3, 0), (3, 5), (4, 5)],
    .sonnet: [(3, 0), (3, 5), (3, 7), (4, 0), (4, 5), (4, 6), (5, 0)],
    .opus:   [(3, 0), (4, 0), (4, 5), (4, 6), (4, 7), (4, 8)],
    .fable:  [(5, 0)],
    .mythos: [(5, 0)],
]

/// Maps every model to a stable, curated color by placing all models on one
/// ordered spectrum.
///
/// **Layout.** Four intelligence classes sit ~90° apart on the hue wheel so
/// they never blur into each other: Haiku (green), Sonnet (blue), Opus
/// (purple), and the creative pair Fable (orange) + Mythos (red) — the two
/// closest colors, since they share a class. Each family owns a band centered
/// on its class hue; a family's versions run oldest → newest across the band,
/// so the newest *builds toward* the next tier.
///
/// **Within a family** the band splits per major version (with a gap between
/// majors, so `Opus 4.x` and `Opus 5.x` clearly differ), and minors are
/// placed by a *blend*: a floor keeps adjacent minors (4.6 / 4.7 / 4.8)
/// distinct, while larger version-number gaps (3.0 → 3.5) get proportionally
/// more room. The result is deterministic — the same model set always
/// produces the same colors.
public struct PacerModelPalette: Sendable {

    /// Class-hue center per family. Haiku/Sonnet/Opus are ~90° apart; Fable &
    /// Mythos straddle the warm "creative" center (~40°) so they're the
    /// closest pair.
    private static let center: [PacerModelIdentity.Family: Double] = [
        .haiku: 130, .sonnet: 220, .opus: 310, .fable: 52, .mythos: 26,
    ]
    /// Half-band width per family. The single-family classes get a wide band;
    /// Fable/Mythos get a narrow one so they stay tight around their anchors.
    private static let halfBand: [PacerModelIdentity.Family: Double] = [
        .haiku: 32, .sonnet: 32, .opus: 32, .fable: 10, .mythos: 10,
    ]
    /// Blend spacing constants (tunable). `minGap` is the floor between any two
    /// versions (keeps adjacent minors distinct); `slope` scales the extra
    /// room a larger version-number difference earns; `majorGap` is the dead
    /// space added at a major-version boundary.
    private static let minGap = 3.0, slope = 1.1, majorGap = 6.0

    private struct Key: Hashable {
        let family: PacerModelIdentity.Family
        let major: Int
        let minor: Int
    }
    private let hues: [Key: Double]

    public init(catalog: [PacerModelIdentity.Family: [(major: Int, minor: Int)]] = pacerModelCatalog) {
        var hues: [Key: Double] = [:]
        for (family, raw) in catalog {
            guard let center = Self.center[family], let bw = Self.halfBand[family] else { continue }
            let versions = raw.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
            guard !versions.isEmpty else { continue }

            // Cumulative blend positions along the band.
            var pos: [Double] = [0]
            for i in 1..<versions.count {
                let prev = versions[i - 1], cur = versions[i]
                let diff = Double((cur.major * 10 + cur.minor) - (prev.major * 10 + prev.minor))
                let boundary = cur.major != prev.major ? Self.majorGap : 0
                pos.append(pos[i - 1] + Self.minGap + Self.slope * diff + boundary)
            }
            let span = max(pos.last ?? 1, 0.0001)
            for (i, v) in versions.enumerated() {
                let frac = versions.count == 1 ? 0.5 : pos[i] / span
                let hue = (center - bw + frac * 2 * bw).truncatingRemainder(dividingBy: 360)
                hues[Key(family: family, major: v.major, minor: v.minor)] = (hue + 360).truncatingRemainder(dividingBy: 360)
            }
        }
        self.hues = hues
    }

    /// Build a palette from the bundled catalog unioned with the user's
    /// OBSERVED model ids — so a model a user actually has that the catalog
    /// doesn't know still gets placed (and reflows its family's band) instead
    /// of only getting the newest-edge fallback. Deterministic for a set.
    public init(observed: [String]) {
        var byFamily: [PacerModelIdentity.Family: Set<[Int]>] = [:]
        for (family, versions) in pacerModelCatalog {
            byFamily[family] = Set(versions.map { [$0.major, $0.minor] })
        }
        for id in observed {
            if let c = PacerModelIdentity(id).canonical {
                byFamily[c.family, default: []].insert([c.major, c.minor])
            }
        }
        var catalog: [PacerModelIdentity.Family: [(major: Int, minor: Int)]] = [:]
        for (family, set) in byFamily {
            catalog[family] = set.map { (major: $0[0], minor: $0[1]) }
        }
        self.init(catalog: catalog)
    }

    /// The color for a raw model id. Parses to a canonical `(family, major,
    /// minor)`; catalogued models use their placed hue, a known family with an
    /// uncatalogued version lands at the family's newest edge (so a just-
    /// shipped version reads as the family's latest), and anything with no
    /// recognized family falls back to the generated hash color.
    public func color(for modelId: String) -> Color {
        guard let c = PacerModelIdentity(modelId).canonical else {
            return pacerGeneratedColor(pacerShortModel(modelId))
        }
        if let hue = hues[Key(family: c.family, major: c.major, minor: c.minor)] {
            return colorAt(hue)
        }
        // Known family, uncatalogued version (rare — a version we haven't added
        // to the catalog yet). Place it just PAST the band's newest edge, into
        // the gap toward the next tier, nudged by version rank so it stays
        // distinct from the catalogued newest and from other new versions.
        guard let center = Self.center[c.family], let bw = Self.halfBand[c.family] else {
            return pacerGeneratedColor(pacerShortModel(modelId))
        }
        let rank = Double(c.major) + Double(c.minor) / 10.0
        let extra = min(max((rank - 4.0) * 2.5, 1.5), 12.0)
        return colorAt((center + bw + extra).truncatingRemainder(dividingBy: 360))
    }

    private func colorAt(_ hue: Double) -> Color {
        let (l, c) = pacerRidge(hue)
        return pacerOKLCH(l: l, c: c, hueDegrees: hue)
    }

    /// The representative color for a whole family/class — its band's center
    /// hue. Used when the Models tab groups by class so a class reads the same
    /// color there as its versions do in the per-model view, and stays on the
    /// ~90°-apart class anchors (already well separated: Opus purple, Sonnet
    /// blue, Haiku green, Fable orange, Mythos red).
    public static func classColor(_ family: PacerModelIdentity.Family) -> Color {
        guard let hue = center[family] else {
            return pacerGeneratedColor(family.rawValue)
        }
        let (l, c) = pacerRidge(hue)
        return pacerOKLCH(l: l, c: c, hueDegrees: hue)
    }
}

/// The active model palette behind `pacerModelColor`. Starts from the bundled
/// catalog (so colors are stable and identical for every user before any data
/// loads) and is rebuilt with the user's observed models via
/// `pacerRefreshModelPalette(observed:)` on scan completion. A lock guards it
/// so the rebuild can run off the main actor while SwiftUI reads it on-main.
private let pacerPaletteLock = NSLock()
nonisolated(unsafe) private var pacerActiveModelPalette = PacerModelPalette()

/// Rebuild the active palette to also include the user's observed model ids.
/// Cheap (dozens of models); call it whenever the seen-model set may change.
public func pacerRefreshModelPalette(observed: [String]) {
    let palette = PacerModelPalette(observed: observed)
    pacerPaletteLock.lock()
    pacerActiveModelPalette = palette
    pacerPaletteLock.unlock()
}

/// A thread-safe snapshot of the current palette. Used by `pacerModelColor`.
func pacerCurrentModelPalette() -> PacerModelPalette {
    pacerPaletteLock.lock()
    defer { pacerPaletteLock.unlock() }
    return pacerActiveModelPalette
}
