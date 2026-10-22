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

    private func render(_ name: String, width: CGFloat, dark: Bool, _ view: some View) throws {
        let framed = view
            .padding(16)
            .frame(width: width, alignment: .topLeading)
            .background(dark ? Color(white: 0.13) : Color(white: 0.98))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
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

    @Test("regular and compact, light and dark")
    func renderBreakdowns() throws {
        for dark in [false, true] {
            try render("breakdown-regular", width: 680, dark: dark,
                       PacerCostBreakdownView(Self.lifetime))
            try render("breakdown-regular-today", width: 680, dark: dark,
                       // The slot as Today's traffic fills it.
                       PacerCostBreakdownView(Self.today) {
                           Text("52× reuse")
                               .font(.system(size: 11))
                               .foregroundStyle(.tertiary)
                           Text("saved $412")
                               .font(.system(size: 11, weight: .semibold, design: .rounded))
                               .foregroundStyle(.green)
                       })
            try render("breakdown-compact", width: 280, dark: dark,
                       PacerCostBreakdownView(Self.lifetime, style: .compact))
            try render("breakdown-compact-today", width: 280, dark: dark,
                       PacerCostBreakdownView(Self.today, style: .compact))
            // Roughly the History page: the Lifetime tiles, then the
            // breakdown card — to see the two read as one page.
            try render("history-mock", width: 720, dark: dark, VStack(spacing: 16) {
                PacerCard("Lifetime") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 4),
                        alignment: .leading
                    ) {
                        MetricTile(value: pacerCost(Self.lifetime.total), label: "cost", size: .hero)
                        MetricTile(value: pacerTokens(Self.lifetime.tokens.all), label: "tokens")
                        MetricTile(value: "214", label: "active days")
                        MetricTile(value: "9", label: "models")
                    }
                }
                PacerCard("Cost breakdown") {
                    PacerCostBreakdownView(Self.lifetime)
                }
            })
        }
    }
}
