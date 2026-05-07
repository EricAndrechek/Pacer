import SwiftUI

/// View modifier that presents a centered, click-outside-to-dismiss
/// modal overlay. macOS sheets are inherently modal — users can't
/// dismiss by clicking the chrome outside the sheet rectangle, only
/// the close button or Escape — which the user flagged as "needs
/// fixes." This wraps SwiftUI's `.overlay` plus a tap-capturing
/// dimming layer to give us sheet-like presentation with
/// "tap-anywhere-outside" dismiss.
///
/// Usage:
///
///     SomeListView()
///         .dismissibleModal(item: $selectedProject) { item in
///             ProjectDetailView(...)
///         }
///
/// `Item: Identifiable` so SwiftUI can animate identity changes.
/// Setting the binding to nil dismisses; the dimming layer's tap
/// gesture and the inner content's `Environment(\.dismiss)` both
/// hand control back to the binding via the same path.
extension View {
    func dismissibleModal<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(DismissibleModalModifier(item: item, modalContent: content))
    }
}

private struct DismissibleModalModifier<Item: Identifiable, ModalContent: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let modalContent: (Item) -> ModalContent

    func body(content: Content) -> some View {
        content
            .overlay(modalLayer)
    }

    /// Builds a fresh dismiss action for each presentation. The
    /// closure captures the @Binding to clear it. Always invoked from
    /// MainActor (SwiftUI body context).
    private func makeDismissAction() -> DismissModalAction {
        DismissModalAction { item = nil }
    }

    @ViewBuilder
    private var modalLayer: some View {
        if let current = item {
            ZStack {
                // Tap-to-dismiss scrim. `contentShape` makes the whole
                // dim area hit-testable even though it has no opaque
                // body — without it, `onTapGesture` only registers on
                // pixels the fill draws (which is everywhere with
                // .opacity(0.35), but spelling it out is robust to
                // future opacity changes).
                Color.black
                    .opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        item = nil
                    }
                // Modal content. We provide a `dismiss` environment
                // value so the inner view can wire its Close button to
                // the same path. The keyboardShortcut(.cancelAction)
                // on Close still routes through this binding.
                modalContent(current)
                    .environment(\.dismissModal, makeDismissAction())
                    // Keep the user from seeing a transparent corner
                    // sliver — the inner views own their padding +
                    // chrome.
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 12)
                    .padding(40)
                    // Esc dismisses, mirroring sheet behavior.
                    .background {
                        Button("") { item = nil }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                    }
            }
            .transition(.opacity)
            .zIndex(1)
        }
    }
}

/// Lightweight value passed through the environment so a modal-content
/// view can dismiss itself without owning the binding. Mirrors
/// `DismissAction`'s shape — call it with `()` to dismiss.
///
/// `@unchecked Sendable` because EnvironmentKey requires Sendable, and
/// the wrapped closure is always invoked from MainActor in practice
/// (SwiftUI view bodies are @MainActor-bound). The compiler can't
/// prove that without crossing the closure-isolation boundary.
struct DismissModalAction: @unchecked Sendable {
    fileprivate let close: () -> Void
    func callAsFunction() { close() }
}

private struct DismissModalKey: EnvironmentKey {
    static let defaultValue = DismissModalAction(close: {})
}

extension EnvironmentValues {
    /// Dismiss the enclosing dismissible modal, if any. Inner views
    /// read this with `@Environment(\.dismissModal)` and call it from
    /// a Close button or any other dismissal control.
    var dismissModal: DismissModalAction {
        get { self[DismissModalKey.self] }
        set { self[DismissModalKey.self] = newValue }
    }
}
