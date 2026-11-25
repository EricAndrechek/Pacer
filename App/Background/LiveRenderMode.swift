import AppKit
import SwiftUI
import SwiftData
import PacerCore

/// Renders the real dashboard, against the real store, to PNGs — so a change
/// can be *looked at* without asking the user to look at it.
///
/// `ScreenshotMode` already hosts views off-screen and spins the run loop so
/// `@Query` fetches and `@State` caches populate before the bitmap is taken.
/// The only thing it could not do is show what the user is actually seeing: it
/// seeds synthetic data by design, because its output ships in the README.
///
/// This reuses the same renderer against `PacerStore`'s real container, opened
/// **read-only**, and walks the scopes. It exists because several rounds of
/// "does this look right to you?" could have been one render and a look.
///
/// The live meter is built once from that store before anything is drawn
/// (`LiveMeterBoard.buildOnce`), so every page shows the estimates the app
/// would, not bare readings. The `menu` page is the menu bar's dropdown.
///
/// Two pages do not depend on the scope and are drawn once per run, in each
/// state they have: `sidebar` (the window's sidebar, its footer up to date,
/// downloading and ready to install; `PACER_RENDER_UPDATE_STATE`, e.g.
/// `ready:0.9.5` or `downloading:0.9.5,failed`, names the states instead;
/// the first and last also in light, the last also at the sidebar's narrowest)
/// and `feedback` (the Send Feedback window: each kind, a failed send with the
/// GitHub fallback, filled in with attachments, sent, and two in light).
///
/// Run it alongside the live app:
///
///     PACER_SCREENSHOT_MODE=1 PACER_RENDER_LIVE=auto \
///     PACER_SCREENSHOT_DIR=/tmp/render open -g -a Pacer
///
/// `auto` means all-accounts plus every account. Or name scopes explicitly:
/// `PACER_RENDER_LIVE=all,<accountId>`.
///
/// `PACER_RENDER_UNPRICED=<model>[,<model>…]` (make: `UNPRICED=`) draws those
/// raw model ids as having no price yet, beside the ones the store says have
/// none, so the "price pending" mark can be looked at on real rows: e.g.
/// `make render-live SCOPES=all PAGES=dashboard,models UNPRICED=claude-opus-4-7`.
///
/// Safety, in order of how badly each would go wrong:
///
/// - **Read-only container.** A second process writing the live store while the
///   app is running is not something to find out about later.
/// - **The scope is set ephemerally.** `UsageScope.select` persists to App Group
///   defaults, which the *running* app reads — walking the scopes with it would
///   leave the user's dashboard wherever this render happened to stop.
/// - **Off-screen and never activated**, inheriting `ScreenshotMode`'s window
///   suppression, because this runs beside an app the user is looking at.
@MainActor
enum LiveRenderMode {

    static var isActive: Bool {
        LaunchMode.isActive(.liveRender)
    }

    /// What to render. Whole tabs by default; `PACER_RENDER_PAGES` takes a
    /// comma-separated subset when iterating on one of them.
    enum Page: String, CaseIterable {
        case dashboard, history, projects, models, now, pace, badges, settings
        /// The compare-models sheet for the scope's 5-hour and 7-day windows.
        case projection, projectionWeekly
        /// The 7-day sheet with the grader line and Speed up control a
        /// catch-up shows (`ProjectionCompareModal.catchUpPreview`): a render
        /// has no arena runtime, so it never has a catch-up of its own. The
        /// weekly window because every plan has one; an Ultra account has no
        /// 5-hour window, so a 5-hour sheet renders empty there.
        case projectionCatchUp
        /// The same sheet sped up on several cores, slowed by memory pressure,
        /// and paused by critical pressure: what only a click on a real
        /// catch-up or real pressure shows otherwise.
        case projectionSpedUp, projectionSlowed, projectionPaused
        /// Every model's info popover, for both windows.
        case modelInfo
        /// The menu bar's dropdown: the SwiftUI content of the status menu
        /// (`MenuStatusContent`), without the native items below it.
        case menu
        /// The window's sidebar with its footer, once per update state
        /// (`variants`).
        case sidebar
        /// The Send Feedback window, once per kind and once after a failed
        /// send (`variants`).
        case feedback

        /// Wide enough that the balanced grids take their many-column layout —
        /// a narrow render exercises a fallback the user is not looking at.
        var width: CGFloat {
            switch self {
            case .dashboard, .history, .projects, .models: return 1200
            // Settings is a single column of cards; wider only stretches them.
            case .settings: return 820
            case .pace: return 1100
            case .now, .badges: return 900
            case .projection, .projectionWeekly, .projectionCatchUp, .projectionSpedUp, .projectionSlowed,
                 .projectionPaused:
                return 760
            case .modelInfo: return 1040
            case .menu: return MenuStatusContent.popoverWidth
            // The sidebar's ideal width (`DashboardSidebar`).
            case .sidebar: return 230
            case .feedback: return 480
            }
        }

        /// The states a scope-independent page is drawn in, each as its own
        /// PNG (`live-<page>-<suffix>.png`); nil for every other page, which
        /// is drawn once per scope.
        @MainActor var variants: [(suffix: String, scheme: ColorScheme, view: AnyView)]? {
            switch self {
            case .sidebar:
                let states = LiveRenderMode.updateStates
                // Every state in dark, then the two ends of the footer in
                // light, and the ready state at the narrowest the sidebar
                // drags to, where the version takes a shorter form.
                return states.map { state in
                    (state.token, .dark, AnyView(SidebarRender(state: state)))
                } + [states.first, states.last].compactMap { $0 }.map { state in
                    ("\(state.token)-light", .light, AnyView(SidebarRender(state: state)))
                } + [states.last].compactMap { $0 }.map { state in
                    ("\(state.token)-narrow", .dark, AnyView(SidebarRender(state: state, width: 166)))
                }
            case .feedback:
                func window(_ view: FeedbackView) -> AnyView {
                    // Its title bar is empty and transparent: the same gap.
                    AnyView(view.padding(.top, 28).background(Color(nsColor: .windowBackgroundColor)))
                }
                let failed = FeedbackView.Phase.failed(FeedbackCopy.failure(.failed(status: 502)) ?? "")
                var all: [(String, ColorScheme, AnyView)] = FeedbackKind.allCases.map { kind in
                    (kind.rawValue, .dark, window(FeedbackView(kind: kind, onClose: {})))
                }
                all.append(("failed", .dark, window(FeedbackView(kind: .problem, phase: failed, onClose: {}))))
                all.append(("filled", .dark, window(FeedbackView(kind: .problem, sample: true, onClose: {}))))
                all.append(("sent", .dark, window(FeedbackView(phase: .sent, onClose: {}))))
                all.append(("idea-light", .light, window(FeedbackView(kind: .idea, onClose: {}))))
                all.append(("filled-light", .light, window(FeedbackView(kind: .problem, sample: true, onClose: {}))))
                return all
            default:
                return nil
            }
        }

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .dashboard: DashboardView()
            case .history:   HistoryView()
            case .projects:  ProjectsView()
            case .models:    ModelsView()
            case .now:       NowStrip()
            case .pace:      PaceChartCard(limitAccountId: UsageScope.shared.limitAccountId)
            case .badges:    AdvisorBadges(scopeAccountId: UsageScope.shared.accountId)
            // Read-only like every other page here — the cards bind to
            // SwiftData, and this process opens the store read-only, so a
            // stray click is not possible and a write would fail loudly.
            case .settings:  SettingsView()
            case .projection:
                ProjectionCompareModal(windowKey: RateLimitWindowName.fiveHour,
                                       limitAccountId: UsageScope.shared.limitAccountId)
            case .projectionWeekly:
                ProjectionCompareModal(windowKey: RateLimitWindowName.sevenDay,
                                       limitAccountId: UsageScope.shared.limitAccountId)
            case .projectionCatchUp:
                ProjectionCompareModal(windowKey: RateLimitWindowName.sevenDay,
                                       limitAccountId: UsageScope.shared.limitAccountId,
                                       catchUpPreview: ArenaPace(mode: .share(.inUse)))
            case .projectionSpedUp:
                ProjectionCompareModal(windowKey: RateLimitWindowName.sevenDay,
                                       limitAccountId: UsageScope.shared.limitAccountId,
                                       catchUpPreview: ArenaPace(mode: .cores(ArenaWorkerPolicy.forThisMac),
                                                                 speedUpUntil: .distantFuture))
            case .projectionSlowed:
                ProjectionCompareModal(windowKey: RateLimitWindowName.sevenDay,
                                       limitAccountId: UsageScope.shared.limitAccountId,
                                       catchUpPreview: ArenaPace(mode: .share(.lowMemory)))
            case .projectionPaused:
                ProjectionCompareModal(windowKey: RateLimitWindowName.sevenDay,
                                       limitAccountId: UsageScope.shared.limitAccountId,
                                       catchUpPreview: ArenaPace(mode: .paused))
            case .menu:
                // On a menu's own surface, as it drops: the page canvas
                // behind every other render is not what a menu sits on.
                MenuStatusContent()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            case .sidebar, .feedback:
                // Drawn through `variants`, never here.
                EmptyView()
            case .modelInfo:
                VStack(alignment: .leading, spacing: 0) {
                    Text("5-hour").font(.headline).padding(.horizontal, 16).padding(.top, 16)
                    ModelInfoGallery(windowKey: RateLimitWindowName.fiveHour, duration: 5 * 3600,
                                     limitAccountId: UsageScope.shared.limitAccountId)
                    Text("7-day").font(.headline).padding(.horizontal, 16)
                    ModelInfoGallery(windowKey: RateLimitWindowName.sevenDay, duration: 7 * 86400,
                                     limitAccountId: UsageScope.shared.limitAccountId)
                }
            }
        }
    }

    /// The update states the `sidebar` page is drawn in: up to date,
    /// downloading and ready by default (checking and a failed check look like
    /// up to date there), or what `PACER_RENDER_UPDATE_STATE` names.
    static var updateStates: [UpdateState] {
        let raw = ProcessInfo.processInfo.environment["PACER_RENDER_UPDATE_STATE"] ?? ""
        let named = raw.split(separator: ",").compactMap { UpdateState(override: String($0)) }
        if !named.isEmpty { return named }
        let next = sampleNextVersion(after: UpdateStatus.currentVersion)
        return [.upToDate, .downloading(version: next), .readyToInstall(version: next)]
    }

    /// A version for the default renders to offer: the next patch of this
    /// build's, or of the last release when this is a dev build.
    private static func sampleNextVersion(after label: AppVersionLabel) -> String {
        guard case .release(let version) = label.kind else { return "0.9.5" }
        var parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return "0.9.5" }
        if parts.count == 2 { parts.append(0) }
        parts[parts.count - 1] += 1
        return parts.map(String.init).joined(separator: ".")
    }

    static var pages: [Page] {
        let raw = ProcessInfo.processInfo.environment["PACER_RENDER_PAGES"] ?? ""
        guard !raw.isEmpty else { return Page.allCases }
        return raw.split(separator: ",").compactMap { Page(rawValue: String($0)) }
    }

    /// The scopes to render, from `PACER_RENDER_LIVE`.
    static func scopes(in context: ModelContext) -> [(label: String, accountId: String?)] {
        let raw = ProcessInfo.processInfo.environment["PACER_RENDER_LIVE"] ?? ""
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        if raw == "auto" {
            return [("all", nil)] + accounts.map { (String($0.id.suffix(4)), $0.id) }
        }
        return raw.split(separator: ",").map(String.init).map { token in
            token == "all" ? ("all", nil) : (String(token.suffix(4)), token)
        }
    }

    /// A read-only handle on the real store.
    static func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(url: try PacerStore.storeURL(), allowsSave: false))
    }

    /// Models to draw as unpriced on top of the store's, from
    /// `PACER_RENDER_UNPRICED`.
    static var forcedUnpriced: Set<String> {
        let raw = ProcessInfo.processInfo.environment["PACER_RENDER_UNPRICED"] ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    static func run(container: ModelContainer) async {
        let context = ModelContext(container)
        let host = EngineHost(container: container)
        let targets = scopes(in: context)
        log("rendering \(targets.count) scope(s) → \(ScreenshotMode.outputDirectory.path)")

        // No scan runs here to publish the unpriced set, so take the one the
        // app's last reconcile stored, plus any forced for a look at the mark.
        let unpriced = UnpricedModels.stored(in: context).union(forcedUnpriced)
        PricePending.shared.update(unpriced)
        if !unpriced.isEmpty { log("price pending: \(unpriced.sorted().joined(separator: ", "))") }

        // Warm every engine the store has, not just the requested scopes. In
        // parallel mode the pace card asks *each account's* engine even when
        // the scope is "all accounts", and a cold engine answers
        // `.insufficient` — which draws a chart with no forecast and reads as
        // a bug that is really an empty cache. Rendering `SCOPES=all` alone
        // produced exactly that.
        let allAccounts = (try? context.fetch(FetchDescriptor<Account>()))?.map(\.id) ?? []
        for accountId in [nil] + allAccounts.map(Optional.init) {
            let engine = host.engine(forAccount: accountId)
            await Task.detached(priority: .userInitiated) { await engine.recompute() }.value
        }
        log("warmed \(allAccounts.count + 1) engine(s)")

        // The live meter, built once from this read-only store: without it
        // every surface draws Anthropic's last readings, where the app draws
        // its estimates. Nothing rebuilds it after this, and nothing is
        // written.
        await LiveMeterBoard.shared.buildOnce(container: container)
        let live = LiveMeterBoard.shared.values
        log("live meter: \(live.values.reduce(0) { $0 + $1.values.filter(\.isEstimate).count }) estimate(s) "
            + "across \(live.count) account(s)")

        for (index, target) in targets.enumerated() {
            UsageScope.shared.selectEphemeral(target.accountId)
            // Warm this scope's engine before drawing, or every engine-powered
            // caption renders its "warming up" state and the render says
            // nothing about the thing being diagnosed.


            // Whole tabs, not individual cards: a sweep wants everything the
            // user can see, including the parts nobody has thought to suspect.
            // `PACER_RENDER_PAGES` narrows it when iterating on one.
            for page in pages {
                if let variants = page.variants {
                    // The same in every scope: drawn with the first only.
                    guard index == 0 else { continue }
                    for variant in variants {
                        await OffscreenRenderer.render(
                            name: "live-\(page.rawValue)-\(variant.suffix)",
                            width: page.width, scheme: variant.scheme,
                            container: container, engines: host
                        ) { variant.view }
                    }
                    continue
                }
                await OffscreenRenderer.render(
                    name: "live-\(page.rawValue)-\(target.label)",
                    width: page.width, scheme: .dark,
                    container: container, engines: host
                ) { page.view }
            }
        }
        UsageScope.shared.selectEphemeral(UsageScope.storedAccountId)
        UpdateStatus.shared.forced = nil
        log("done")
    }

    private static func log(_ message: String) {
        // lint:allow stderr-write diagnostic mode only (never the user's app): its output is the terminal that started the run
        FileHandle.standardError.write(Data("[Pacer live-render] \(message)\n".utf8))
    }
}

/// The sidebar as the window draws it, with its footer forced into one update
/// state. At the window's minimum height, on the window background: the split
/// view's sidebar material is not drawn off-screen.
private struct SidebarRender: View {
    let state: UpdateState
    /// Narrower than the page, to draw the sidebar dragged in.
    var width: CGFloat?
    @State private var selection: ContentView.Destination = .dashboard

    var body: some View {
        DashboardSidebar(selection: $selection)
            .frame(width: width, height: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            // Set as the view appears, so each variant draws its own state
            // (the renderer draws them one after another).
            .onAppear { UpdateStatus.shared.forced = state }
    }
}
