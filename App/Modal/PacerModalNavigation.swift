import SwiftUI

/// Native sheet + NavigationStack wrapper. Every modal-reachable
/// detail view in Pacer (Day / Project / Session) is presented
/// through this surface so the app inherits Apple's sheet animation,
/// toolbar chrome, back chevron, ⌘[ shortcut, and trackpad swipe-back
/// for free.
///
/// **Why a native sheet now:** an earlier iteration used a custom
/// click-outside-to-dismiss overlay with a hand-rolled stack of
/// destinations because `NavigationStack` inside that overlay
/// delegated pushes to the outer `NavigationSplitView` on macOS
/// Sequoia. A real `.sheet` presents in its own context, so
/// `NavigationStack` inside the sheet stays scoped — which lets us
/// drop the custom chrome HStack, the hidden-button keyboard
/// shortcuts, the `NSEvent` swipe monitor, and the `DismissibleModal`
/// overlay altogether (~400 LOC of custom code).
///
/// Trade-off: macOS sheets are inherently modal, so users dismiss via
/// `Esc` / the toolbar's Done button rather than click-outside.
///
/// Adding a new modal-reachable detail view:
/// 1. Add a case to `PacerModalDestination`.
/// 2. Resolve it in `PacerModalDestinationView`.
/// 3. Push from anywhere with `@Environment(\.pacerModalPush) var
///    push; push(.yourCase(...))`.

// MARK: - Destination

/// Everything the modal stack can navigate to. `Identifiable` so
/// `.sheet(item:)` can present the root entry by identity; `Hashable`
/// so `NavigationStack(path:)` can diff pushed/popped values.
public enum PacerModalDestination: Hashable, Identifiable {
    /// One calendar day's per-model and per-project detail.
    case day(date: String)
    /// A single project's drill-down — daily activity, models, sessions.
    case project(path: String, displayName: String, since: Date?)
    /// One session's full transcript metadata.
    case session(sessionId: String, projectDisplayName: String)

    public var id: String {
        switch self {
        case .day(let d):                return "day:\(d)"
        case .project(let path, _, _):   return "project:\(path)"
        case .session(let sid, _):       return "session:\(sid)"
        }
    }
}

// MARK: - Push action (environment)

/// Closure-shaped value plumbed through the environment so drill-down
/// views can append to the parent's navigation path without owning
/// the path themselves. Mirrors SwiftUI's own `DismissAction` shape.
public struct PacerModalPushAction: @unchecked Sendable {
    fileprivate let push: (PacerModalDestination) -> Void
    public func callAsFunction(_ destination: PacerModalDestination) {
        push(destination)
    }
}

private struct PacerModalPushKey: EnvironmentKey {
    static let defaultValue = PacerModalPushAction { _ in }
}

public extension EnvironmentValues {
    /// Push another destination onto the current modal's
    /// NavigationStack. No-op outside a modal context, so a stray
    /// call from an out-of-modal view is harmless.
    var pacerModalPush: PacerModalPushAction {
        get { self[PacerModalPushKey.self] }
        set { self[PacerModalPushKey.self] = newValue }
    }
}

// MARK: - Destination router

/// Resolves a `PacerModalDestination` to its concrete view. Used as
/// the root of the NavigationStack and as the
/// `.navigationDestination(for:)` factory, so the root and pushed
/// entries share one resolution path.
struct PacerModalDestinationView: View {
    let destination: PacerModalDestination

    var body: some View {
        switch destination {
        case .day(let date):
            DayDetailView(date: date)
        case .project(let path, let displayName, let since):
            ProjectDetailView(
                projectPath: path,
                displayName: displayName,
                since: since
            )
        case .session(let sessionId, let projectDisplayName):
            SessionDetailView(
                sessionId: sessionId,
                projectDisplayName: projectDisplayName
            )
        }
    }
}

// MARK: - Modifier

extension View {
    /// Attach the unified modal navigation surface to a page. The
    /// page owns the binding to the root destination; the modifier
    /// hosts the sheet, the NavigationStack, and the push action.
    func pacerModalNavigation(
        root: Binding<PacerModalDestination?>
    ) -> some View {
        modifier(PacerModalNavigationModifier(root: root))
    }
}

private struct PacerModalNavigationModifier: ViewModifier {
    @Binding var root: PacerModalDestination?
    /// NavigationStack path scoped to the active sheet. Reset to
    /// empty whenever the sheet dismisses so re-opening the modal
    /// doesn't surface a previously-pushed detail view.
    @State private var path: [PacerModalDestination] = []

    func body(content: Content) -> some View {
        content.sheet(item: $root) { rootDest in
            NavigationStack(path: $path) {
                PacerModalDestinationView(destination: rootDest)
                    .navigationDestination(for: PacerModalDestination.self) { dest in
                        PacerModalDestinationView(destination: dest)
                    }
            }
            // Sheet-level Done lives on the NavigationStack, not on
            // each detail view. SwiftUI on macOS accumulates
            // `.toolbar` items from every view in the stack — a
            // Done in every view rendered as "Reveal in Finder •
            // Reveal transcript • Open JSONL • Done" once a Session
            // was pushed inside a Project. Declaring once here keeps
            // the bottom bar minimal; per-view actions live inline in
            // the content body.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { root = nil }
                }
            }
            .environment(
                \.pacerModalPush,
                PacerModalPushAction { dest in path.append(dest) }
            )
            // Native back navigation. `NavigationStack` already
            // wires up a chevron in the upper-left of the sheet
            // chrome, but Cmd+[ / Cmd+Left aren't attached by
            // default on macOS — these hidden Buttons mirror what
            // Safari / Finder column view use. `.cancelAction`
            // closes the whole sheet (Esc), matching every other
            // Mac sheet's behavior regardless of stack depth.
            .background {
                Button("Back") { if !path.isEmpty { path.removeLast() } }
                    .keyboardShortcut("[", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0)
                    .disabled(path.isEmpty)
                    .accessibilityHidden(true)
            }
            .background {
                Button("Back") { if !path.isEmpty { path.removeLast() } }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0)
                    .disabled(path.isEmpty)
                    .accessibilityHidden(true)
            }
            .background {
                Button("Close") { root = nil }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            // Sheets retain their hosting NSWindow across re-shows.
            // Without this reset, opening a modal → pushing a detail
            // → closing → re-opening the modal would render with the
            // previous detail still on top of the stack.
            .onDisappear { path.removeAll() }
        }
    }
}
