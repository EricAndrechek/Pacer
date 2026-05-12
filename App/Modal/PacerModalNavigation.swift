import SwiftUI
import PacerCore
import PacerUI

/// Unified modal-navigation surface used by Dashboard, History, Projects,
/// and Models. Replaces the prior "stack of `DismissibleModal`s" where
/// each detail view owned its own child modal — that pattern (a) let
/// modals nest infinitely deep, and (b) cascaded Esc/Cmd+W across every
/// modal in the stack.
///
/// **Why a manual stack instead of `NavigationStack`:** an earlier
/// pass used `NavigationStack(path:)` inside the `DismissibleModal`,
/// expecting `.navigationDestination(for:)` to swap the displayed view
/// when the path mutated. On macOS Sequoia, `NavigationStack` inside a
/// custom overlay context delegates the push to the outer
/// `NavigationSplitView`: the modal dismissed and the destination
/// pushed into the main window's detail pane. The manual approach
/// here keeps navigation 100% scoped to the modal: we render only the
/// top-of-stack destination and surface a "Back" button when the
/// stack is non-empty.
///
/// Adding a new modal-reachable detail view:
/// 1. Add a case to `PacerModalDestination`.
/// 2. Resolve it inside `PacerModalRouter`.
/// 3. Push from anywhere with `@Environment(\.pacerModalPush) var
///    push; push(.yourCase(...))`.

// MARK: - Destination

/// Everything the modal stack can navigate to. Must be `Identifiable`
/// (with a stable id) so `.dismissibleModal(item:)` can present the
/// root entry; `Hashable` so the SwiftUI runtime can diff stack
/// changes efficiently.
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
/// views can append to the parent's stack without owning the stack
/// themselves. Mirrors SwiftUI's own `DismissAction` shape.
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
    /// Push another destination onto the modal stack. Returns a no-op
    /// outside a modal context, so a stray call from an out-of-modal
    /// view is harmless.
    var pacerModalPush: PacerModalPushAction {
        get { self[PacerModalPushKey.self] }
        set { self[PacerModalPushKey.self] = newValue }
    }
}

// MARK: - Back action (environment)

/// Pop-one-level action. Detail-view headers use this to render a
/// "Back" chevron next to the title when there's a parent destination
/// to go back to. Optional in the public API — `nil` means "no
/// parent" (i.e. the view is the modal's root).
public struct PacerModalBackAction: @unchecked Sendable {
    fileprivate let pop: () -> Void
    public func callAsFunction() { pop() }
}

private struct PacerModalBackKey: EnvironmentKey {
    static let defaultValue: PacerModalBackAction? = nil
}

public extension EnvironmentValues {
    /// `nil` when the current modal view has nothing to go back to.
    /// Non-nil when there's at least one entry deeper than this view
    /// in the navigation stack; calling it pops one level.
    var pacerModalBack: PacerModalBackAction? {
        get { self[PacerModalBackKey.self] }
        set { self[PacerModalBackKey.self] = newValue }
    }
}

// MARK: - Router

/// Resolves a `PacerModalDestination` to its concrete view.
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
    /// owns the stack and the push/back environment values.
    func pacerModalNavigation(
        root: Binding<PacerModalDestination?>
    ) -> some View {
        modifier(PacerModalNavigationModifier(root: root))
    }
}

private struct PacerModalNavigationModifier: ViewModifier {
    @Binding var root: PacerModalDestination?
    /// Manual stack — the modifier swaps which entry is rendered, so
    /// only one detail view exists in the SwiftUI hierarchy at any
    /// time and there's no inner NavigationStack to fight with the
    /// outer NavigationSplitView.
    @State private var stack: [PacerModalDestination] = []

    func body(content: Content) -> some View {
        content
            .dismissibleModal(item: $root) { rootDest in
                let current = stack.last ?? rootDest
                // `id(current.id)` forces SwiftUI to treat each
                // destination as its own subtree — without it, the
                // @Query bindings inside ProjectDetailView /
                // DayDetailView would persist across pushes (a click
                // into Project A's detail then a back-and-into
                // Project B would show A's data briefly).
                PacerModalRouter(destination: current)
                    .id(current.id)
                    .environment(
                        \.pacerModalPush,
                        PacerModalPushAction { dest in
                            stack.append(dest)
                        }
                    )
                    .environment(
                        \.pacerModalBack,
                        stack.isEmpty ? nil : PacerModalBackAction {
                            if !stack.isEmpty { stack.removeLast() }
                        }
                    )
            }
            // Reset the stack whenever the root flips back to nil —
            // otherwise a closed-and-reopened modal would still have
            // the previous drill-in pushed onto it.
            .onChange(of: root == nil) { _, isNil in
                if isNil { stack.removeAll() }
            }
    }
}

// MARK: - Detail-view header back chevron

/// Header trailing button that renders a "‹ Back" affordance when the
/// modal stack has a parent destination, and nothing otherwise. Drop
/// it into a detail view's header HStack on the leading side to give
/// the user a clear way to step up one level.
struct PacerModalBackButton: View {
    @Environment(\.pacerModalBack) private var back

    var body: some View {
        if let back {
            Button {
                back()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Go back one step")
        }
    }
}
