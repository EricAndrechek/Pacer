import CoreGraphics
import Foundation

/// Whether a remembered window frame is worth putting a window back into.
///
/// The obvious test — "does this frame touch a connected screen?" — is the
/// one that shipped, and it is too generous in a way that only shows up
/// when a display goes away. `CGRect.intersects` is true for *any* overlap,
/// down to a single point, and it does not care *which* screen was
/// overlapped. So a frame parked near the right-hand edge of a wide display
/// still "fits" after that display is unplugged, by clipping the corner of
/// whatever monitor happens to sit next to where it used to be — and the
/// window is restored into mostly dead space with a strip showing.
///
/// The rule here is that enough of the window has to land on one screen to
/// be worth looking at. A frame that fails is not discarded: the caller
/// leaves the window where it is and keeps the frame for when the display
/// it belongs to comes back.
public enum WindowPlacementFit {

    /// Smaller than this and the window is a sliver — the user ends up
    /// staring at nothing whether or not it is on a screen.
    public static let minimumSize = CGSize(width: 480, height: 320)

    /// How much of the window has to be on one screen.
    ///
    /// A judgement call rather than a platform rule. Half is comfortably
    /// past "deliberately hanging off the edge" and comfortably short of
    /// "restored into the gap where a monitor used to be".
    public static let minimumVisibleFraction: CGFloat = 0.5

    /// - Parameter visibleFrames: `NSScreen.visibleFrame` for each
    ///   connected screen — the menu bar and Dock already excluded.
    public static func isRestorable(_ frame: CGRect, onAnyOf visibleFrames: [CGRect]) -> Bool {
        guard frame.width >= minimumSize.width, frame.height >= minimumSize.height else {
            return false
        }
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }

        return visibleFrames.contains { screen in
            let overlap = screen.intersection(frame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return false }
            let overlapArea = overlap.width * overlap.height
            if overlapArea >= frameArea * minimumVisibleFraction { return true }
            // A window bigger than the display it lives on can never cover
            // half of *itself*. Covering half the display is the same
            // statement from the other side, and is what a window sized for
            // an ultrawide looks like when it is restored onto one.
            let screenArea = screen.width * screen.height
            return screenArea > 0 && overlapArea >= screenArea * minimumVisibleFraction
        }
    }
}
