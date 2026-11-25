import SwiftUI
import PacerCore

/// Pacer's own version in secondary text, "Pacer 0.9.4" or "Pacer dev ·
/// 1a2b3c4", with the build number on hover. Selectable, so it can be pasted
/// into a report. Takes the label as a plain value.
public struct PacerVersionLabel: View {
    let label: AppVersionLabel

    public init(_ label: AppVersionLabel) {
        self.label = label
    }

    public var body: some View {
        Text(label.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
            .help(label.buildLine ?? label.title)
    }
}

/// The in-window update action. Nothing while there is nothing to act on
/// (up to date, checking, a failed check), a quiet "Downloading 0.9.5…"
/// while one downloads, and a prominent "Update to 0.9.5 · Restart" once it is
/// ready. `install` runs on the click; the caller decides what that does.
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
        switch state {
        case .readyToInstall(let version):
            Button(action: install) {
                Label(UpdateCopy.sidebarInstall(version), systemImage: "arrow.down.circle")
                    .lineLimit(1)
                    // A long version in a narrow sidebar shrinks a little
                    // rather than truncating the word that says what it does.
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        case .downloading(let version):
            Text(UpdateCopy.downloading(version))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .upToDate, .checking, .failed:
            EmptyView()
        }
    }
}
