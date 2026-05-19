import Foundation
import WidgetKit
import PacerCore

/// Bridge between scan-cycle events posted by `PacerCore` and the
/// `WidgetKit` extension that renders Pacer's widgets.
///
/// **Why this exists.** The widget extension lives in a separate
/// process and reads the shared SwiftData store through its
/// `TimelineProvider`. Without an explicit kick from the host app, it
/// only refreshes when its last-returned `Timeline.policy` says to —
/// and `.after(...)` is advisory, gated by WidgetKit's daily reload
/// budget. The practical result is a Notification Center widget
/// showing data that's tens of minutes stale even though the host app
/// has been updating live the whole time.
///
/// Calling `WidgetCenter.shared.reloadTimelines(ofKind:)` after every
/// store write tells WidgetKit "there's new data; please ask my
/// provider for a fresh timeline." That's the missing piece — the
/// widget's own `getTimeline` then re-reads SwiftData and re-renders.
///
/// **Why throttling matters.** A chatty Claude Code session can fire
/// `pacerScanCycleDidComplete` several times a minute. Each
/// `reloadTimelines` call costs WidgetKit budget; reloading every
/// widget on every signal would burn the daily budget in minutes,
/// after which WidgetKit ignores us entirely and the widgets stop
/// refreshing again — exactly the failure mode this coordinator is
/// trying to fix.
///
/// So each kind has its own `Throttler` with a leading + trailing
/// firing pattern:
///   - First signal in a quiet period fires immediately (leading edge),
///     so the user sees freshness right away when activity resumes.
///   - Subsequent signals within `minimumInterval` set a "pending"
///     flag. When the window expires, if pending is still set, the
///     trailing edge fires once. This coalesces bursty signals into
///     one reload per interval.
///
/// Per-kind intervals reflect how "live" each widget actually needs
/// to feel — see `Throttler.minimumInterval`.
@MainActor
final class WidgetRefreshCoordinator {

    private var observer: NSObjectProtocol?
    /// One throttler per kind. Keyed by the widget's `kind` string so
    /// lookup is a single dictionary access on the hot path.
    private var throttlers: [String: Throttler] = [:]

    init() {
        for kind in WidgetKinds.all {
            throttlers[kind] = Throttler(
                kind: kind,
                minimumInterval: Self.minimumInterval(for: kind)
            )
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .pacerScanCycleDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // `object` is the ScanCycleSummary the poster attached.
            // The notification name is namespaced (`com.ericandrechek.pacer.…`)
            // so a spurious post from someone else is highly unlikely,
            // but a defensive cast keeps us from crashing if a future
            // refactor breaks the contract.
            guard let summary = note.object as? ScanCycleSummary else { return }
            // Notification queue is `.main`, so the closure runs on
            // the main thread — but it's not @MainActor-typed from
            // NotificationCenter's perspective. Hop into the actor to
            // mutate throttler state safely.
            MainActor.assumeIsolated {
                self?.handle(summary)
            }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        for throttler in throttlers.values {
            throttler.cancel()
        }
    }

    // MARK: - Summary → kinds

    /// Map a `ScanCycleSummary` to the set of widget kinds that should
    /// reload, then dispatch each through its throttler.
    ///
    /// Mapping rationale:
    ///   - `samplesChanged` — new TokenSamples landed, which means
    ///     daily/project-daily aggregates and session info all
    ///     recomputed. That touches every widget except the pace ones
    ///     (which key off `RateLimitSample`).
    ///   - `rateLimitsChanged` — only the OAuth poller writes these;
    ///     only the pace widgets read them.
    ///   - `projectAttributionChanged` — alias-driven re-bucketing.
    ///     Project rankings shifted (TopProjects) and the live
    ///     session's `projectPath` may now resolve to a different
    ///     display name (LiveSession). DailyChart is keyed by
    ///     (date, model) not project, so it skips this signal.
    private func handle(_ summary: ScanCycleSummary) {
        if summary.samplesChanged {
            request(kind: WidgetKinds.liveSession)
            request(kind: WidgetKinds.todayCost)
            request(kind: WidgetKinds.dailyChart)
            request(kind: WidgetKinds.topProjects)
        }
        if summary.rateLimitsChanged {
            request(kind: WidgetKinds.paceChart)
            request(kind: WidgetKinds.paceGauges)
        }
        if summary.projectAttributionChanged {
            request(kind: WidgetKinds.liveSession)
            request(kind: WidgetKinds.topProjects)
        }
    }

    private func request(kind: String) {
        throttlers[kind]?.request()
    }

    /// Per-kind throttle interval. The minimum gap between consecutive
    /// `reloadTimelines(ofKind:)` calls for a given widget.
    ///
    /// **What the throttle actually prevents.** `reloadTimelines` is
    /// cheap on its own — WidgetKit coalesces redundant calls and
    /// decides separately when to invoke our `getTimeline`. The
    /// throttle's job is to keep us from spamming WidgetKit during a
    /// chatty Claude Code session where scan cycles fire every couple
    /// seconds; the leading edge still fires immediately so the first
    /// signal in a quiet period propagates without delay.
    ///
    /// **Why these specific values.** A user comparing the dashboard
    /// to a widget side-by-side expects them to agree within seconds,
    /// not minutes — that's the failure mode the previous coarser
    /// throttles (5-minute DailyChart/TopProjects) couldn't handle.
    /// 60s is the slowest reasonable cap: today's bar on a daily
    /// chart lagging by a minute is invisible; lagging by five
    /// minutes looks broken.
    ///
    /// LiveSession is even tighter (15s) because it's literally the
    /// "current-activity" widget — sub-minute freshness is the whole
    /// product promise.
    private static func minimumInterval(for kind: String) -> TimeInterval {
        switch kind {
        case WidgetKinds.liveSession: return 15
        default:                      return 60
        }
    }
}

// MARK: - Throttler

/// Per-kind throttle with leading + trailing edge semantics.
///
/// State machine:
///   - `lastFiredAt` is the last time we actually called
///     `reloadTimelines`. Initialized to `.distantPast` so the first
///     `request()` always fires immediately.
///   - `pendingTrailingTask` is non-nil iff we've scheduled a delayed
///     fire because a request came in during the cooldown window.
///     Subsequent requests during the same cooldown ride on that
///     task — they don't schedule additional tasks.
@MainActor
private final class Throttler {
    let kind: String
    let minimumInterval: TimeInterval

    private var lastFiredAt: Date = .distantPast
    private var pendingTrailingTask: Task<Void, Never>?

    init(kind: String, minimumInterval: TimeInterval) {
        self.kind = kind
        self.minimumInterval = minimumInterval
    }

    func request() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFiredAt)
        if elapsed >= minimumInterval {
            // Leading edge — outside cooldown, fire immediately.
            fire()
            return
        }
        // Inside cooldown. A trailing task already scheduled? Just
        // ride on it; calling reloadTimelines multiple times within
        // the same window is the budget waste we're trying to avoid.
        guard pendingTrailingTask == nil else { return }
        let delay = minimumInterval - elapsed
        pendingTrailingTask = Task { [weak self] in
            // Sleep until end of the cooldown window. If cancel()
            // fires (coordinator shutting down), Task.sleep throws
            // CancellationError — swallow it and exit.
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.pendingTrailingTask = nil
            self.fire()
        }
    }

    func cancel() {
        pendingTrailingTask?.cancel()
        pendingTrailingTask = nil
    }

    private func fire() {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        lastFiredAt = Date()
    }
}
