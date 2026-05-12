import SwiftUI
import PacerCore
import PacerUI

/// Unified modal-navigation surface used by Dashboard, History, Projects,
/// and Models. The pattern replaces the prior "stack of `DismissibleModal`s"
/// where each detail view owned its own child modal state — that pattern
/// (a) let modals nest infinitely deep, and (b) cascaded Esc/Cmd+W to
/// every modal in the stack at once because every level registered its
/// own cancel-action keyboard shortcut.
///
/// New pattern: ONE `DismissibleModal` per page hosting a
/// `NavigationStack`. Drill-in clicks inside detail views push onto the
/// stack via `@Environment(\.pacerModalPush)`; the user navigates back
/// with the navigation bar's native back button. Esc and Cmd+W dismiss
/// the whole modal (DismissibleModal's keyboard shortcut still fires
/// once at the page level — no cascade because there's only one modal).
///
/// Adding a new modal-reachable detail view:
/// 1. Add a case to `PacerModalDestination`.
/// 2. Resolve it inside `PacerModalRouter`.
/// 3. Push from anywhere with `@Environment(\.pacerModalPush) var push;
///    push(.yourCase(...))`.

// MARK: - Destination

/// Everything the modal stack can navigate to. Must be `Hashable` so
/// `NavigationStack(path:)` can identify entries, and `Identifiable`
/// (with a stable id) so `.dismissibleModal(item:)` can present the
/// root entry.
public enum PacerModalDestination: Hashable, Identifiable {
    /// One calendar day's per-model and per-project detail.
    case day(date: String)
    /// A single project's drill-down — daily activity, models, sessions.
    case project(path: String, displayName: String, since: Date?)
    /// One session's full transcript metadata. Stored as id + project
    /// display name so the destination is Hashable; the view does its
    /// own `@Query<SessionInfo>` lookup by id.
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
/// views can append to the parent's NavigationPath without owning the
/// path themselves. Mirrors SwiftUI's own `DismissAction` shape.
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
    /// Push another destination onto the modal stack. Inner detail
    /// views read this to drill deeper — e.g. DayDetailView pushes
    /// `.project(...)` when the user clicks a project row. Returns a
    /// no-op outside a modal context, so a stray call from an
    /// out-of-modal view is harmless.
    var pacerModalPush: PacerModalPushAction {
        get { self[PacerModalPushKey.self] }
        set { self[PacerModalPushKey.self] = newValue }
    }
}

// MARK: - Router

/// Resolves a `PacerModalDestination` to its concrete view. Pulled out
/// of the modifier so the same switch handles both the root destination
/// and stacked destinations.
struct PacerModalRouter: View {
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
    /// owns the NavigationPath and the push environment value.
    ///
    /// Usage:
    /// ```
    /// @State private var modalRoot: PacerModalDestination?
    /// PageScaffold(...) { ... }
    ///     .pacerModalNavigation(root: $modalRoot)
    /// ```
    func pacerModalNavigation(
        root: Binding<PacerModalDestination?>
    ) -> some View {
        modifier(PacerModalNavigationModifier(root: root))
    }
}

private struct PacerModalNavigationModifier: ViewModifier {
    @Binding var root: PacerModalDestination?
    /// NavigationStack path. Reset to empty whenever the modal closes
    /// so reopening the same root doesn't carry leftover pushes.
    @State private var path: [PacerModalDestination] = []

    func body(content: Content) -> some View {
        content
            .dismissibleModal(item: $root) { rootDest in
                NavigationStack(path: $path) {
                    PacerModalRouter(destination: rootDest)
                        .navigationDestination(
                            for: PacerModalDestination.self
                        ) { dest in
                            PacerModalRouter(destination: dest)
                        }
                }
                .environment(
                    \.pacerModalPush,
                    PacerModalPushAction { dest in
                        path.append(dest)
                    }
                )
            }
            // Reset the stack whenever the root flips back to nil —
            // otherwise a closed-and-reopened modal would still have
            // the previous drill-in pushed onto it.
            .onChange(of: root == nil) { _, isNil in
                if isNil { path.removeAll() }
            }
    }
}
