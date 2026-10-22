import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PacerCore
@testable import PacerUI

/// Renders `PacerCostBreakdownView` to PNGs so its layout can be looked at
/// without launching the app: regular and compact, light and dark, on a
/// realistic mix. Off by default; CI never runs it.
///
///     PACER_RENDER_UI=1 swift test --filter CostBreakdownRender
///
/// Output goes to `PACER_RENDER_UI_DIR`, or `pacer-render-ui/` under the
/// temporary directory.
@Suite("Cost breakdown render", .enabled(if: ProcessInfo.processInfo.environment["PACER_RENDER_UI"] != nil))
@MainActor
struct CostBreakdownRenderTests {

    private var outputDir: URL {
        if let dir = ProcessInfo.processInfo.environment["PACER_RENDER_UI_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-render-ui", isDirectory: true)
    }

    /// A lifetime-sized mix close to a real store's: cache reads ~77% of the
    /// cost and ~98% of the tokens.
    private static let lifetime = CostBreakdown(
        cost: CostComponents(
            input: 8.12, output: 1_310.4, cacheRead: 12_603.12,
            cacheWrite5m: 1_512.75, cacheWrite1h: 978.3),
        tokens: TokenBreakdown(
            inputTokens: 1_623_000, outputTokens: 52_400_000,
            cacheReadTokens: 21_512_345_678,
            cacheCreation5mTokens: 242_000_000, cacheCreation1hTokens: 97_800_000))

    /// One day, no 1h writes: the quiet $0 part.
    private static let today = CostBreakdown(
        cost: CostComponents(
            input: 0.04, output: 18.2, cacheRead: 61.7, cacheWrite5m: 14.9),
        tokens: TokenBreakdown(
            inputTokens: 8_100, outputTokens: 728_000,
            cacheReadTokens: 123_400_000, cacheCreation5mTokens: 2_380_000))

    /// A real Today's traffic: input $0.04 of ~$489 (0.008%), output 10.5%,
    /// reads 56.2%, 5m writes 13.2%, 1h writes 20.1%. The input part is a
    /// twentieth of a point at card width: the sliver that drew a hairline,
    /// a gap and a bar end that looked cut off.
    private static let sliver = CostBreakdown(
        cost: CostComponents(
            input: 0.04, output: 51.3, cacheRead: 274.8,
            cacheWrite5m: 64.5, cacheWrite1h: 98.3),
        tokens: TokenBreakdown(
            inputTokens: 9_300, outputTokens: 2_050_000,
            cacheReadTokens: 549_600_000, cacheCreation5mTokens: 10_320_000,
            cacheCreation1hTokens: 9_830_000))

    private func render(
        _ name: String, width: CGFloat, dark: Bool, scale: CGFloat = 2, _ view: some View
    ) throws {
        let framed = view
            .padding(16)
            .frame(width: width, alignment: .topLeading)
            .background(dark ? Color(white: 0.13) : Color(white: 0.98))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try #require(renderer.cgImage)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let suffix = dark ? "dark" : "light"
        let url = outputDir.appendingPathComponent("\(name)-\(suffix).png")
        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// The sliver case at full card width, as Today's traffic draws it, and
    /// the bar's two ends blown up.
    @Test("a sliver at the bar's end, light and dark")
    func renderSliver() throws {
        for dark in [false, true] {
            try render("breakdown-sliver-card", width: 860, dark: dark,
                       PacerCard("Today's traffic") {
                           PacerCostBreakdownView(Self.sliver)
                       })
            // The Day detail modal's width: the narrowest a regular legend
            // gets, where the fine print ("242M tokens · 1.25×") has the
            // least room.
            try render("breakdown-sliver-modal", width: 560, dark: dark,
                       PacerCostBreakdownView(Self.sliver))
            try render("breakdown-sliver-bar-zoom", width: 260, dark: dark, scale: 8,
                       PacerCostBar(Self.sliver, height: 10))
            // The tables' Mix bar: 6 pt high, so a 3 pt part is a sliver.
            try render("breakdown-sliver-mix-zoom", width: 120, dark: dark, scale: 8,
                       PacerCostBar(Self.sliver, height: 6))
        }
    }

    @Test("regular and compact, light and dark")
    func renderBreakdowns() throws {
        for dark in [false, true] {
            try render("breakdown-regular", width: 680, dark: dark,
                       PacerCostBreakdownView(Self.lifetime))
            try render("breakdown-regular-today", width: 680, dark: dark,
                       PacerCostBreakdownView(Self.today))
            try render("breakdown-compact", width: 280, dark: dark,
                       PacerCostBreakdownView(Self.lifetime, style: .compact))
            try render("breakdown-compact-today", width: 280, dark: dark,
                       PacerCostBreakdownView(Self.today, style: .compact))
        }
    }
}
