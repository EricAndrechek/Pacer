import AppKit
import SwiftUI
import SwiftData
import PacerCore

/// Realize a SwiftUI view in an off-screen window, let its lifecycle run, and
/// write a PNG.
///
/// Extracted from `ScreenshotMode` so the live-store renderer can use the same
/// path rather than a second copy of it. The subtlety worth keeping in one
/// place: a one-shot `ImageRenderer` pass captures before `@Query` has fetched
/// and before the `@State` scan-tick caches have refreshed, so cards come out
/// empty. A real window plus a spun run loop is what makes them populate.
@MainActor
enum OffscreenRenderer {

    /// Render `content` at `width` (height from its ideal size) and write
    /// `<name>.png` into `ScreenshotMode.outputDirectory`.
    static func render(
        name: String,
        width: CGFloat,
        scheme: ColorScheme,
        container: ModelContainer,
        engines: EngineHost? = nil,
        engine: UsageIntelligenceEngine? = nil,
        @ViewBuilder _ content: () -> some View
    ) async {
        let inner = content()
            .modelContainer(container)
            .environment(\.usageEngine, engine ?? engines?.global)
            .environment(\.usageEngines, engines)
            .frame(width: width)
            .padding(28)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(scheme)

        let hosting = NSHostingView(rootView: AnyView(inner))
        hosting.frame = NSRect(x: 0, y: 0, width: 5000, height: 5000)
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        await snapshot(hosting,
                       size: CGSize(width: ceil(fit.width), height: ceil(fit.height)),
                       name: name, scheme: scheme)
    }

    /// Off-screen, never-activated, non-opaque window (so transparency is
    /// preserved), the SwiftUI lifecycle given time to run, then a PNG.
    static func snapshot(
        _ hosting: NSHostingView<AnyView>, size: CGSize, name: String, scheme: ColorScheme
    ) async {
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -60_000, y: -60_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()

        // Spin the run loop so SwiftUI mounts, @Query fetches land, the
        // @State scan-tick caches refresh, and Charts lay out.
        //
        // Generous, and deliberately so: at 2.6 s the Now tile captured before
        // its engine answers arrived, so the render showed a bare card and
        // sent me looking for a bug the live app did not have. A renderer that
        // under-waits does not fail — it lies.
        await settle(seconds: 5.0)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        await settle(seconds: 1.0)

        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            log("⚠️ could not allocate bitmap for \(name)"); return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            log("⚠️ could not encode PNG for \(name)"); return
        }
        do {
            try FileManager.default.createDirectory(
                at: ScreenshotMode.outputDirectory, withIntermediateDirectories: true)
            try png.write(to: ScreenshotMode.outputDirectory.appendingPathComponent("\(name).png"))
            log("✓ \(name).png (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } catch {
            log("⚠️ write failed for \(name): \(error)")
        }
    }

    static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[Pacer render] \(message)\n".utf8))
    }
}
