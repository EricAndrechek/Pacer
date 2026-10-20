import SwiftUI

/// An ⓘ beside a label: one line on hover, the full answer in a popover on
/// click. For a row whose "what is this?" doesn't fit inline, such as a
/// forecast model in the compare sheet. Plain values plus a content slot, so
/// any screen can explain any row without copying the control.
///
/// Uses `.help()`, so it belongs in the app's own windows; a menu-bar surface
/// needs `pacerToolTip` instead (see `ToolTip.swift`).
public struct PacerInfoButton<Content: View>: View {
    let help: String
    let content: () -> Content
    @State private var shown = false

    public init(help: String, @ViewBuilder content: @escaping () -> Content) {
        self.help = help
        self.content = content
    }

    public var body: some View {
        Button { shown.toggle() } label: {
            // The icon reads `shown`, so this body owns the dependency the
            // popover's binding writes to.
            Image(systemName: shown ? "info.circle.fill" : "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(shown ? .secondary : .tertiary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("More about this")
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            content()
                .padding(14)
                .frame(width: 300, alignment: .leading)
        }
    }
}
