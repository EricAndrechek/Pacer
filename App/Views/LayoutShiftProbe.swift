import SwiftUI
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
