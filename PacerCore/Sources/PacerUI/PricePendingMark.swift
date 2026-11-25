import SwiftUI
import PacerCore

/// What the "price pending" mark says, apart from the view so it is tested
/// without one. A cost that includes a model with no price yet reads low
/// (that model's share is $0), and the mark says so where the number is,
/// instead of leaving a legal-looking total. It goes once the price arrives
/// (`PricePending`), and the ledger reprices the history then too.
public enum PacerPricePending {

    /// The mark's SF Symbol.
    public static let symbol = "hourglass"

    /// The tooltip for a cost that includes `models` (raw ids), or nil when
    /// it includes none, which is also when no mark is drawn.
    public static func help(_ models: [String]) -> String? {
        guard !models.isEmpty else { return nil }
        // Named by the canonical model a price is added under, so two
        // spellings of one model (a `[1m]` variant, a Bedrock id) name it once.
        var names: [String] = []
        for model in models {
            let name = pacerModelDisplayName(CanonicalModelID.parse(model).model)
            if !names.contains(name) { names.append(name) }
        }
        return "No price yet for \(names.joined(separator: ", ")); costs update once one is published"
    }
}

/// The quiet mark beside a cost that includes a model with no price yet:
/// a small tertiary glyph with the tooltip `PacerPricePending.help` gives.
/// Draws nothing for an empty `models`, so a caller can always place it.
///
/// `menuBar`: also set the AppKit tooltip, for content hosted in the menu
/// bar's dropdown, where `.help()` does nothing on macOS 26+ (`pacerToolTip`).
public struct PacerPricePendingMark: View {
    let models: [String]
    let size: CGFloat
    let menuBar: Bool

    public init(models: [String], size: CGFloat = 9, menuBar: Bool = false) {
        self.models = models
        self.size = size
        self.menuBar = menuBar
    }

    public var body: some View {
        if let help = PacerPricePending.help(models) {
            let mark = Image(systemName: PacerPricePending.symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help(help)
                .accessibilityLabel(help)
            if menuBar {
                mark.pacerToolTip(help)
            } else {
                mark
            }
        }
    }
}
