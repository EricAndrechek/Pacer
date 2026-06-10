import SwiftUI
import AppKit

/// The "share this chart" popover: a live preview of the exact image
/// that will be produced, with Copy / Save / Share actions beneath it.
///
/// Generic over the card via `makeCard(scheme)` so the same composition
/// renders in the current appearance both on screen and in the exported
/// PNG — and so a future cost/heatmap share is just a different closure.
/// The image is rendered lazily, only when an action is invoked, so
/// merely opening the popover stays cheap.
struct ChartShareSheet: View {
    let fileName: String
    let makeCard: (ColorScheme) -> AnyView

    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    @State private var shareAnchor = ShareAnchorBox()

    var body: some View {
        VStack(spacing: 16) {
            card
            actions
        }
        .padding(18)
        .frame(width: ShareCardLayout.width + 36)
    }

    /// The card for the current appearance. Built once per render and
    /// reused for both the preview and the rasterized export so they
    /// can't drift.
    private var card: AnyView { makeCard(scheme) }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: copyImage) {
                Label(copied ? "Copied!" : "Copy image",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .disabled(copied)

            Button(action: saveImage) {
                Label("Save as PNG…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }

            Button(action: shareImage) {
                Label("Share…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            // A zero-footprint AppKit anchor so the system share picker
            // has a real NSView + rect to point its popover at. Filling
            // the button's background makes the picker hang off the
            // Share button itself.
            .background(ShareAnchorView(box: shareAnchor))
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
    }

    // MARK: actions

    private func copyImage() {
        guard let image = ChartImageRenderer.nsImage(for: card) else { return }
        ChartImageExporter.copyToPasteboard(image)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }

    private func saveImage() {
        guard let data = ChartImageRenderer.pngData(for: card) else { return }
        ChartImageExporter.savePNG(data, suggestedName: fileName)
    }

    private func shareImage() {
        guard let image = ChartImageRenderer.nsImage(for: card) else { return }
        shareAnchor.present([image])
    }
}

// MARK: - System share picker anchor

/// Holds the AppKit view the `NSSharingServicePicker` points at. A plain
/// reference type parked in `@State` (we never observe it — we just need
/// a stable instance the representable can write its NSView into and the
/// Share button can read back). Left non-isolated so its initializer is
/// usable as a `@State` default; the only AppKit-touching method is
/// `@MainActor`, and `view` is written from the representable's
/// main-actor callbacks.
final class ShareAnchorBox {
    weak var view: NSView?

    @MainActor
    func present(_ items: [Any]) {
        guard let view, !items.isEmpty else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// Transparent NSView that records itself into the shared `ShareAnchorBox`
/// so the picker can anchor to the Share button's frame.
private struct ShareAnchorView: NSViewRepresentable {
    let box: ShareAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}
