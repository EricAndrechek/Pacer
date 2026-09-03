import SwiftUI

/// A pop-up selector that does not use an AppKit menu.
///
/// SwiftUI's `Menu` and the menu-styled `Picker` both render their popup
/// detached and mis-scaled into a screen corner in this app — observed on the
/// Settings alert-metric `Picker` and on a `Menu` in the dashboard, so it is
/// not specific to one control or one screen. `NSPopover`, which is what
/// `.popover` uses, is positioned by a different path and does not show it.
///
/// This is a workaround, not a diagnosis: the menu problem is still open. It
/// is shared rather than reimplemented per call site so that when the cause is
/// found there is one place to revert, instead of however many copies had
/// accumulated by then.
public struct PacerSelect<Value: Hashable>: View {
    public struct Option: Identifiable {
        public let value: Value
        public let title: String
        /// Quiet text on the right of the row — a plan, a count, a hint.
        public let detail: String?

        public init(value: Value, title: String, detail: String? = nil) {
            self.value = value
            self.title = title
            self.detail = detail
        }

        public var id: Value { value }
    }

    @Binding public var selection: Value
    public let options: [Option]
    public var width: CGFloat?

    @State private var showing = false

    public init(selection: Binding<Value>, options: [Option], width: CGFloat? = nil) {
        self._selection = selection
        self.options = options
        self.width = width
    }

    public var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                Text(selectedTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            PacerChoiceList(
                options: options,
                isSelected: { $0 == selection },
                onPick: { value in
                    selection = value
                    showing = false
                }
            )
            .frame(width: max(width ?? 220, 220))
        }
    }

    private var selectedTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }
}

/// The rows inside a `PacerSelect` popover, shared so any caller needing its
/// own trigger (the toolbar's compact account control) still gets identical
/// row behaviour and spacing.
public struct PacerChoiceList<Value: Hashable>: View {
    public let options: [PacerSelect<Value>.Option]
    public let isSelected: (Value) -> Bool
    public let onPick: (Value) -> Void

    public init(
        options: [PacerSelect<Value>.Option],
        isSelected: @escaping (Value) -> Bool,
        onPick: @escaping (Value) -> Void
    ) {
        self.options = options
        self.isSelected = isSelected
        self.onPick = onPick
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(options) { option in
                let selected = isSelected(option.value)
                Button { onPick(option.value) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(selected
                                ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(.tertiary))
                        Text(option.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
    }
}
