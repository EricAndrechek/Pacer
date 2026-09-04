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
/// Run it alongside the live app:
///
///     PACER_SCREENSHOT_MODE=1 PACER_RENDER_LIVE=auto \
///     PACER_SCREENSHOT_DIR=/tmp/render open -g -a Pacer
///
/// `auto` means all-accounts plus every account. Or name scopes explicitly:
/// `PACER_RENDER_LIVE=all,<accountId>`.
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
        !(ProcessInfo.processInfo.environment["PACER_RENDER_LIVE"] ?? "").isEmpty
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

    static func run(container: ModelContainer) async {
        let context = ModelContext(container)
        let host = EngineHost(container: container)
        let targets = scopes(in: context)
        log("rendering \(targets.count) scope(s) → \(ScreenshotMode.outputDirectory.path)")

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

        for target in targets {
            UsageScope.shared.selectEphemeral(target.accountId)
            // Warm this scope's engine before drawing, or every engine-powered
            // caption renders its "warming up" state and the render says
            // nothing about the thing being diagnosed.


            await OffscreenRenderer.render(
                name: "live-now-\(target.label)", width: 900, scheme: .dark,
                container: container, engines: host
            ) { NowStrip() }

            await OffscreenRenderer.render(
                name: "live-pace-\(target.label)", width: 1100, scheme: .dark,
                container: container, engines: host
            ) { PaceChartCard(limitAccountId: UsageScope.shared.limitAccountId) }

            await OffscreenRenderer.render(
                name: "live-badges-\(target.label)", width: 900, scheme: .dark,
                container: container, engines: host
            ) { AdvisorBadges(scopeAccountId: target.accountId) }
        }
        UsageScope.shared.selectEphemeral(UsageScope.storedAccountId)
        log("done")
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[Pacer live-render] \(message)\n".utf8))
    }
}
