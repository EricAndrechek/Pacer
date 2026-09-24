import SwiftUI
import AppKit
import PacerCore

/// Logs a view's height changes that its *content* caused — the layout shifts
/// and flickers a user sees but cannot name.
///
/// A dashboard jump is over before anyone can say which card moved, and it
/// cannot be reproduced on demand. So the evidence has to already be in the log
/// when someone notices: always on, and cheap because it only writes on a
/// change. A pair of lines a few hundred milliseconds apart (412→110, then
/// 110→412) is a flicker; a single line is a shift.
///
/// Width changes are recorded but not logged: resizing the window re-wraps
/// every card's text, and that is the user moving things, not the app.
struct LayoutShiftProbe: ViewModifier {
    let name: String
    @State private var last: CGSize?
    @State private var lastChangeAt: Date?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            defer { last = size }
            guard let last, abs(last.width - size.width) < 1,
                  abs(last.height - size.height) >= 1 else { return }
            let now = Date()
            let since = lastChangeAt.map { " (\(Int(now.timeIntervalSince($0) * 1000))ms after previous)" } ?? ""
            lastChangeAt = now
            let delta = Int((size.height - last.height).rounded())
            Log.write("LayoutShift",
                      "\(name) height \(Int(last.height.rounded()))→\(Int(size.height.rounded()))"
                        + " (\(delta > 0 ? "+" : "")\(delta))\(since)")
        }
    }
}

extension View {
    func layoutShiftProbe(_ name: String) -> some View {
        modifier(LayoutShiftProbe(name: name))
    }
}

/// Logs the width a toolbar item's SwiftUI content wants against the width
/// AppKit actually gave its slot.
///
/// The freshness pill sometimes renders cut off until a tab switch rebuilds
/// the toolbar, and nobody can make it happen on demand. The suspicion is a
/// slot left at an old label's width — this says whether that is what happens,
/// with the numbers, the next time it does. Mounted as a `.background`, so its
/// own frame is the content's size and its superviews are the hosting chain.
struct ToolbarSlotProbe: NSViewRepresentable {
    let name: String
    let label: String

    func makeNSView(context: Context) -> ProbeView { ProbeView(name: name) }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.label = label
        view.needsLayout = true
    }

    final class ProbeView: NSView {
        let name: String
        var label = ""
        private var lastReport = ""

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        private func report() {
            // The first ancestor that is a hosting view is the slot the toolbar
            // sized; everything above it is AppKit's toolbar machinery.
            var host: NSView? = superview
            while let v = host, !String(describing: type(of: v)).contains("HostingView") {
                host = v.superview
            }
            let wants = Int(frame.width.rounded())
            let slot = host.map { Int($0.frame.width.rounded()) }
            let slotText = slot.map { "\($0)pt" } ?? "?"
            let clipped = slot.map { $0 + 1 < wants } ?? false
            let line = "\(name) \"\(label)\" wants \(wants)pt, slot \(slotText)"
                + (clipped ? " — CLIPPED" : "")
            guard line != lastReport, window != nil else { return }
            lastReport = line
            Log.write("ToolbarSlot", line)
        }
    }
}
