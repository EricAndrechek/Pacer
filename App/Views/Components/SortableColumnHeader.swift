import SwiftUI

/// Clickable column header for an inline sortable table. Renders the
/// label in the same uppercase-tracked style as `Eyebrow`, with a tiny
/// chevron arrow next to the active sort column showing direction.
///
/// Click semantics:
///   - Click an inactive column → activate, default direction (descending
///     for numeric/date columns, ascending for text). Caller decides.
///   - Click the active column → toggle direction.
///
/// The caller owns the active-field + direction state via two bindings.
struct SortableColumnHeader<Field: Equatable>: View {
    let label: String
    let field: Field
    let alignment: Alignment
    @Binding var activeField: Field
    @Binding var descending: Bool
    /// Default direction to use when this column is freshly activated
    /// (descending for cost/tokens, ascending for paths/names). Avoids
    /// having to remember per-column defaults at the call site every
    /// time.
    let defaultDescending: Bool

    init(
        _ label: String,
        field: Field,
        alignment: Alignment = .leading,
        active: Binding<Field>,
        descending: Binding<Bool>,
        defaultDescending: Bool = true
    ) {
        self.label = label
        self.field = field
        self.alignment = alignment
        self._activeField = active
        self._descending = descending
        self.defaultDescending = defaultDescending
    }

    private var isActive: Bool { activeField == field }

    var body: some View {
        Button {
            if isActive {
                descending.toggle()
            } else {
                activeField = field
                descending = defaultDescending
            }
        } label: {
            HStack(spacing: 4) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                if isActive {
                    Image(systemName: descending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
