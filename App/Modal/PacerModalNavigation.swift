import SwiftUI
import AppKit
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
/// **Chrome:** detail views wrap themselves in `PacerModalContent`,
/// which renders a thin toolbar at the top (back + title/subtitle +
/// trailing actions + close) and the scrollable body below. The
/// toolbar reads `pacerModalBack` and `dismissModal` from the
/// environment so the same chrome is reused by every destination.
///
/// **Native interactions** the modifier wires up:
///   - `⌘[` and `⌘←` → pop one level (only while a parent exists).
///   - Two-finger trackpad swipe → pop one level (Safari/Finder-style).
///   - `Esc` / `⌘W` → dismiss the modal entirely (lives on the
///     `DismissibleModal` layer).
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
///
/// `@unchecked Sendable` is correct here: the closure is constructed
/// on MainActor (inside `PacerModalNavigationModifier.body`) and only
/// ever called from MainActor view code that pulled this action out of
/// the environment. Every read and write of the underlying stack runs
/// MainActor-isolated; the unchecked annotation only suppresses Swift
/// 6's inability to infer closure Sendability automatically.
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

/// Pop-one-level action. The chrome reads this to decide whether to
/// render a back chevron; detail views generally don't touch it
/// directly. Optional in the public API — `nil` means "no parent" (the
/// view is the modal's root).
///
/// `@unchecked Sendable` carries the same justification as
/// `PacerModalPushAction`: the closure is created and invoked only on
/// MainActor.
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
                let canGoBack = !stack.isEmpty
                let pop: () -> Void = {
                    if !stack.isEmpty { stack.removeLast() }
                }
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
                        canGoBack ? PacerModalBackAction(pop: pop) : nil
                    )
                    // Native back keyboard shortcuts mirror Safari /
                    // Finder. Hidden Buttons attached as backgrounds —
                    // .keyboardShortcut binds to a single view, so we
                    // stack one per shortcut. `.disabled` gates them
                    // when there's nothing to pop so the shortcut
                    // falls through to whatever else might handle it.
                    .background {
                        Button("Back") { pop() }
                            .keyboardShortcut("[", modifiers: .command)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .disabled(!canGoBack)
                    }
                    .background {
                        Button("Back") { pop() }
                            .keyboardShortcut(.leftArrow, modifiers: .command)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .disabled(!canGoBack)
                    }
                    // Two-finger trackpad swipe-back. Installs a
                    // window-scoped NSEvent monitor while the modal
                    // is on-screen and the stack is non-empty.
                    .background {
                        SwipeBackGestureHost(canGoBack: canGoBack, onBack: pop)
                    }
            }
            // Reset the stack whenever the root flips back to nil —
            // otherwise a closed-and-reopened modal would still have
            // the previous drill-in pushed onto it.
            .onChange(of: root == nil) { _, isNil in
                if isNil { stack.removeAll() }
            }
    }
}

// MARK: - Chrome toolbar wrapper for detail views

/// Standard wrapper every modal-presented detail view uses. Pins a
/// thin toolbar at the top (back chevron + title block + trailing
/// actions + close button) and renders the supplied content in a
/// ScrollView below. The toolbar reads its back / dismiss actions
/// from the environment so the same chrome is reused by every
/// destination without per-view plumbing.
///
/// **Why a wrapper instead of letting each detail view roll its own
/// header HStack:** the previous pattern put the back button, the
/// page title, "Reveal in Finder", and the Close button on the same
/// HStack, sandwiching the title between four control affordances.
/// The title fought the controls for space and the bordered "Back"
/// button looked like a body button rather than chrome. Lifting the
/// chrome into one component lets every modal share a single layout
/// (and one place to fix sizing / styling regressions).
public struct PacerModalContent<Trailing: View, Content: View>: View {
    public let title: String
    public let subtitle: String?
    public let minWidth: CGFloat
    public let idealWidth: CGFloat
    public let minHeight: CGFloat
    public let idealHeight: CGFloat
    public let trailing: () -> Trailing
    public let content: () -> Content

    @Environment(\.pacerModalBack) private var back
    @Environment(\.dismissModal) private var dismiss

    public init(
        title: String,
        subtitle: String? = nil,
        minWidth: CGFloat = 540,
        idealWidth: CGFloat = 620,
        minHeight: CGFloat = 460,
        idealHeight: CGFloat = 560,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.minHeight = minHeight
        self.idealHeight = idealHeight
        self.trailing = trailing
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            chrome
            // ScrollView lives below the chrome so the toolbar stays
            // pinned while content scrolls. `scrollIndicators(.never)`
            // matches every other modal-resident scroll in the app.
            ScrollView {
                VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                    content()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(
            minWidth: minWidth, idealWidth: idealWidth,
            minHeight: minHeight, idealHeight: idealHeight
        )
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            // Back chevron only when there's a parent to return to.
            // Plain icon-button style + secondary tint mimics native
            // toolbar back affordances (Safari, Mail, Finder column
            // view) rather than a bordered body button. The
            // Color.clear placeholder forces the slot to reserve
            // width even when the button isn't rendered, so the
            // title's left edge doesn't shift between root and
            // pushed views.
            ZStack(alignment: .leading) {
                Color.clear
                    .frame(width: 28, height: 22)
                if let back {
                    PacerModalIconButton(
                        systemName: "chevron.backward",
                        help: "Back  ⌘[",
                        accessibilityLabel: "Back",
                        size: 13,
                        action: { back() }
                    )
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fontDesign(.rounded)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                trailing()
            }

            PacerModalIconButton(
                systemName: "xmark",
                help: "Close  Esc",
                accessibilityLabel: "Close",
                size: 11,
                circled: true,
                action: { dismiss() }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - Toolbar icon button

/// Icon-only chrome button used for back / close / Reveal in Finder /
/// transcript open. Plain style (no rectangular fill) so the chrome
/// reads as toolbar rather than body content. Hover lights a soft
/// circular background — matches the visual idiom of native macOS
/// toolbar buttons and toolbar-style controls in Sequoia inspectors.
public struct PacerModalIconButton: View {
    public let systemName: String
    public let help: String
    public let accessibilityLabel: String
    public let size: CGFloat
    public let circled: Bool
    public let action: () -> Void
    @State private var hovering = false

    public init(
        systemName: String,
        help: String,
        accessibilityLabel: String,
        size: CGFloat = 12,
        circled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.circled = circled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(background)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    @ViewBuilder
    private var background: some View {
        if circled {
            Circle()
                .fill(Color.primary.opacity(hovering ? 0.12 : 0.06))
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.10 : 0))
        }
    }
}

// MARK: - Trackpad swipe-back gesture

/// SwiftUI shim that installs a window-scoped NSEvent monitor while
/// the modal is on-screen and the navigation stack is non-empty. When
/// the user does a clearly horizontal two-finger trackpad swipe, the
/// monitor pops one level — same motion Safari / Finder column view /
/// Mail use for "go back."
private struct SwipeBackGestureHost: NSViewRepresentable {
    var canGoBack: Bool
    var onBack: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.attach()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.canGoBack = canGoBack
        context.coordinator.onBack = onBack
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(canGoBack: canGoBack, onBack: onBack)
    }

    /// Coordinator state. `nonisolated(unsafe)` is correct here:
    /// NSEvent local monitor callbacks fire on the main thread
    /// (Cocoa guarantee) and `updateNSView` is `@MainActor`, so
    /// every mutation happens serialized on main — the compiler just
    /// can't prove that across the `(NSEvent) -> NSEvent?` callback
    /// boundary. The `unsafe` opts us out of Swift 6's strict-
    /// concurrency check without forcing us to introduce a
    /// MainActor hop that the AppKit runtime would have served
    /// synchronously anyway.
    final class Coordinator {
        nonisolated(unsafe) var canGoBack: Bool
        nonisolated(unsafe) var onBack: () -> Void
        nonisolated(unsafe) private var monitor: Any?
        /// Accumulated horizontal delta inside the active gesture
        /// phase. Reset on `.began`, sampled on `.changed`, cleared on
        /// `.ended` / `.cancelled` so two consecutive swipes register
        /// independently.
        nonisolated(unsafe) private var accumulatedX: CGFloat = 0
        /// Whether the current gesture has already triggered. Avoids
        /// repeated pops if the user keeps swiping after the threshold
        /// is crossed.
        nonisolated(unsafe) private var firedInGesture = false

        init(canGoBack: Bool, onBack: @escaping () -> Void) {
            self.canGoBack = canGoBack
            self.onBack = onBack
        }

        func attach() {
            // .scrollWheel covers two-finger trackpad swipes (which
            // surface as precise-delta scroll events) without needing
            // System Settings → Trackpad → "Swipe between pages" set
            // to three-finger.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event: event)
                return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit { detach() }

        private func handle(event: NSEvent) {
            guard canGoBack else { return }
            // Precise deltas are emitted by trackpads and Magic Mouse.
            // A regular wheel mouse (line-by-line scrolling) shouldn't
            // pop the modal on a stray horizontal nudge.
            guard event.hasPreciseScrollingDeltas else { return }

            switch event.phase {
            case .began:
                accumulatedX = 0
                firedInGesture = false
            case .changed:
                if firedInGesture { return }
                accumulatedX += event.scrollingDeltaX
                // Only fire when the gesture is dominantly horizontal —
                // a vertical-leaning swipe inside the content scroll
                // shouldn't accidentally pop the modal. ~50pt
                // accumulated rightward delta matches the "deliberate
                // swipe" feel Safari uses.
                let horizontalDominant =
                    abs(accumulatedX) > abs(event.scrollingDeltaY) * 1.5
                if horizontalDominant && accumulatedX > 50 {
                    firedInGesture = true
                    onBack()
                }
            case .ended, .cancelled:
                accumulatedX = 0
                firedInGesture = false
            default:
                break
            }
        }
    }
}
