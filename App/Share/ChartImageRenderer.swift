import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Rasterizes a SwiftUI view (a branded share card) to bitmap output.
///
/// Unlike `ScreenshotMode` — which hosts views off-screen and spins the
/// run loop because its content depends on `@Query` fetches and the
/// SwiftUI lifecycle — share cards are handed their data inline
/// (`PaceChartView.Data` is a plain value), so there's nothing async to
/// wait for and a one-shot `ImageRenderer` pass is enough. The card
/// bakes its own opaque background and an explicit color scheme, so the
/// renderer (which inherits no environment) reproduces the on-screen
/// preview faithfully.
@MainActor
enum ChartImageRenderer {
    /// Pixel density of the exported image. 3× turns the 600pt card into
    /// an ~1800px-wide PNG — crisp on Retina and large enough to post to
    /// socials without upscaling. `nonisolated` so it's usable as a
    /// default-argument value (those evaluate outside the type's actor).
    nonisolated static let exportScale: CGFloat = 3

    static func cgImage(for view: some View, scale: CGFloat = exportScale) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        // Keep transparency so the card's rounded corners read clean on
        // any background it's pasted onto (Slack, Messages, a tweet).
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// An `NSImage` sized in points (for the pasteboard / share sheet)
    /// but backed by the full `scale`× pixel buffer.
    static func nsImage(for view: some View, scale: CGFloat = exportScale) -> NSImage? {
        guard let cg = cgImage(for: view, scale: scale) else { return nil }
        return NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        )
    }

    static func pngData(for view: some View, scale: CGFloat = exportScale) -> Data? {
        guard let cg = cgImage(for: view, scale: scale) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Destinations for a rendered chart image: the clipboard, a file, or
/// (via the picker in `ChartShareSheet`) any macOS sharing service.
/// Mirrors `CSVExporter`'s NSSavePanel-and-reveal-in-Finder flow so the
/// two export surfaces feel the same.
@MainActor
enum ChartImageExporter {
    /// Put the image on the general pasteboard so it can be pasted into
    /// Messages, Slack, a doc, etc.
    static func copyToPasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    /// Prompt for a location and write the PNG, then reveal it in Finder
    /// — matching the post-save behavior of Preview / Numbers and of
    /// Pacer's own CSV export.
    static func savePNG(_ data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.title = "Export chart image"
        panel.message = "Choose where to save the PNG."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Export failed"
            alert.informativeText = "Couldn't write image: \(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
