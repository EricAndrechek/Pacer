import SwiftUI
import PacerCore

/// Stacked concentric rings in the Apple Watch activity-ring visual
/// language. Each ring renders a 0–1 progress fraction with a
/// gradient stroke, rounded leading cap, and (when ≥ 100%) a subtle
/// glow that signals "completed" — the same affordances watchOS uses
/// to communicate state at a glance.
///
/// Scale-aware: works at menu-bar size (~14pt) all the way up to the
/// dashboard hero (~120pt). Line width and inter-ring gap are
/// derived from the frame so the rings stay readable at every size
/// without per-call-site tuning.
public struct ActivityRings: View {
    /// One ring. Order in the array maps to outer → inner.
    public struct Ring: Equatable, Sendable {
        public let progress: Double  // 0...1 (clamped on draw)
        public let color: Color
        public let label: String?

        public init(progress: Double, color: Color, label: String? = nil) {
            self.progress = progress
            self.color = color
            self.label = label
        }
    }

    public let rings: [Ring]
    /// Optional center content (e.g., a percent label). Caller decides
    /// what to put there; can be `EmptyView()` for icon-only contexts
    /// like the menu bar.
    let centerContent: AnyView

    public init<Content: View>(
        rings: [Ring],
        @ViewBuilder center: () -> Content = { EmptyView() }
    ) {
        self.rings = rings
        self.centerContent = AnyView(center())
    }

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            // Line width scales with size — narrow at menu-bar size,
            // chunky at dashboard size. Tuned so 16pt renders ~2pt
            // strokes (visible but not heavy) and 120pt renders
            // ~12pt strokes (Apple-Watch-style chunky).
            let lineWidth = max(1.5, size * 0.085)
            let gap = max(1.0, size * 0.025)

            ZStack {
                ForEach(rings.indices, id: \.self) { idx in
                    ringView(
                        ring: rings[idx],
                        diameter: size - CGFloat(idx) * (lineWidth + gap) * 2,
                        lineWidth: lineWidth
                    )
                }
                centerContent
            }
            .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func ringView(ring: Ring, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        let fraction = max(0, min(1, CGFloat(ring.progress)))
        ZStack {
            // Background track — same hue as the foreground but
            // heavily desaturated, so the ring reads as one
            // continuous element with two states. Matches watchOS.
            Circle()
                .stroke(ring.color.opacity(0.18), lineWidth: lineWidth)
            // Foreground arc with a sweeping gradient. The start of
            // the arc is brighter; the end fades into the band
            // color. Renders at any fraction; the round line cap
            // gives the leading edge that Apple-Watch "ball" look.
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            ring.color.opacity(0.85),
                            ring.color
                        ]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * Double(fraction))
                    ),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            // Capped-ring glow: at ≥ 100% we overdraw a faint outer
            // ring in the same color, mimicking watchOS's "ring
            // closed" celebration. Subtle — meant as polish, not a
            // distraction.
            if fraction >= 1.0 {
                Circle()
                    .stroke(ring.color.opacity(0.45), lineWidth: lineWidth * 1.6)
                    .blur(radius: lineWidth * 0.6)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
