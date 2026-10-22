import SwiftUI

/// A big table that is its own card: the card's title over the table's
/// native header, the rows running to the card's edges, and the card's
/// rounded corners and hairline around both.
///
/// A usage table used to sit inside a `PacerCard`, inset by the card's
/// padding and drawn with its own rounded border: a bordered table inside a
/// bordered card, which the owner found too nested (a "Sessions · 88 total"
/// card holding a rounded table was the example). Here the table's surface
/// is the card's. The title, its trailing slot and an optional footer take
/// the card's own padding; the table takes only enough to line its first
/// column up under the title.
public struct PacerTableCard<Trailing: View, Content: View, Footer: View>: View {
    let title: String
    let trailing: () -> Trailing
    let content: () -> Content
    let footer: () -> Footer

    /// Horizontal inset of the table inside the card. The inset table style
    /// starts its first cell 16pt in, so 4 more puts the label under the
    /// title at the card's 20pt padding.
    static var tableInset: CGFloat { PacerDesign.cardPadding - 16 }

    public init(
        _ title: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.trailing = trailing
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // The same title as every other card (`PacerCard`).
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, PacerDesign.cardPadding)
            .padding(.top, PacerDesign.cardPadding)
            .padding(.bottom, 2)
            content()
                .padding(.horizontal, Self.tableInset)
                .padding(.bottom, Footer.self == EmptyView.self ? 6 : 0)
            if Footer.self != EmptyView.self {
                footer()
                    .padding(.horizontal, PacerDesign.cardPadding)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                .fill(PacerDesign.cardBackground)
        )
        // The table draws to the card's edges; its rows and header stop at
        // the card's corners.
        .clipShape(RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                .stroke(PacerDesign.cardStroke, lineWidth: 1)
        )
    }
}
