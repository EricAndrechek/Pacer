import SwiftUI
import PacerCore

/// The sidebar's last line: which Pacer this is, "Pacer 0.9.4" or "Pacer
/// 0.9.4+14 · dev (9eb8c89)", and while an update downloads, that instead.
///
/// The version is shown in the longest form the width has room for
/// (`AppVersionLabel.fittedTitles`), so a dev build in a narrow sidebar loses
/// its commit whole rather than ending in "(6764…". The full label and the
/// build number are on hover; the text is selectable, to paste into a report.
///
/// Takes the label and the state as plain values, so the caller's body is
/// what reads the observable status.
public struct PacerVersionLabel: View {
    let label: AppVersionLabel
    let state: UpdateState

    public init(_ label: AppVersionLabel, state: UpdateState = .upToDate) {
        self.label = label
        self.state = state
    }

    public var body: some View {
        Group {
            if case .downloading(let version) = state {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(UpdateCopy.downloading(version))
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach(label.fittedTitles, id: \.self) { form in
                        Text(form)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help([label.title, label.buildLine].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// The in-window update action: nothing until an update is available or
/// ready, then a row in the sidebar rows' own grammar (icon, label, the same
/// insets) on an accent wash, "Restart to Update" over "Pacer 0.9.5 is ready",
/// or "… is available" for one that downloads when clicked (#470). Dimmed and
/// "Restarting…" once the install has started. `install` runs on the click;
/// the caller decides what that does.
///
/// A wash rather than a solid accent fill: the selected destination is the
/// solid one, and two of those read as two selections.
///
/// Takes the state as a value, so the caller's body is what reads the
/// observable status, and this redraws with it.
public struct PacerUpdateAction: View {
    let state: UpdateState
    let install: () -> Void

    public init(state: UpdateState, install: @escaping () -> Void) {
        self.state = state
        self.install = install
    }

    public var body: some View {
        // One branch for ready and installing, so the row keeps its identity
        // when a click starts the install and only dims.
        if let version = state.readyVersion {
            UpdateRow(version: version, available: state.isAvailable, installing: state.isInstalling,
                      install: install)
        }
    }
}

private struct UpdateRow: View {
    let version: String
    let available: Bool
    let installing: Bool
    let install: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: install) {
            // The icon goes first when the sidebar is dragged to its
            // narrowest: the words say what the click does.
            ViewThatFits(in: .horizontal) {
                content(icon: true)
                content(icon: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering && !installing ? 0.26 : 0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(installing)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(UpdateCopy.sidebarInstall), \(subtitle)")
    }

    private var subtitle: String {
        available ? UpdateCopy.sidebarAvailable(version) : UpdateCopy.sidebarReady(version)
    }

    private func content(icon: Bool) -> some View {
        HStack(spacing: 10) {
            if icon {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body.weight(.medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(installing ? UpdateCopy.sidebarInstalling : UpdateCopy.sidebarInstall)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            // Only the narrowest sidebar at a large text size gets here.
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
    }
}
