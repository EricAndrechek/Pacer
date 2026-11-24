import Foundation

// MARK: - Why this exists (#407)
//
// With every display asleep, macOS slows the whole process: on one Mac's log
// the main thread logged 1,200–1,800 stalls an hour asleep against 2–600
// awake, the same forecast refit cost 15 s of CPU against 6 s, and a chart
// body pass 2–5 ms against 0.06 ms. Under memory pressure Pacer's pages are
// compressed or swapped too, so any view work that touches them stalls. All of
// that was dashboard work nobody could see.
//
// The rule this gate keeps: **nobody may ever look at a view that is not
// current.** So it pauses exactly one thing in exactly one state:
//
// - **Only when every display is asleep.** Not a locked screen, an occluded or
//   unfocused window, a minimised one, an inactive app: a dashboard on another
//   monitor, under a translucent terminal or on a Sidecar iPad is being looked
//   at. Asleep must be confirmed by asking CoreGraphics about every online
//   display, and anything unclear counts as awake.
// - **Only the dashboard window's refresh signals.** The data path never waits:
//   scanning, polling, persistence, the forecast engine, the local API and the
//   CLI, widget reloads, notifications and the menu-bar label all keep running
//   on the raw signals, which this does not touch.
//
// It coalesces at the source rather than in each view. While every display is
// asleep it remembers which signals fired (and, for a scan cycle, the union of
// what changed) without delivering them. On wake it delivers each one exactly
// once, at once, and lets every held minute tick run. Every view already
// refreshes on these signals (AGENTS.md, "Every cached value needs an explicit
// trigger"), so nothing per view decides anything, and a view that was missed
// here simply keeps its old, always-current behaviour.

/// A dashboard refresh signal the gate can hold while every display sleeps.
public enum ViewRefreshSignal: String, Sendable, CaseIterable {
    /// `pacerScanCycleDidComplete`, relayed as `pacerViewScanCycleDidComplete`.
    case scanCycle = "scan cycle"
    /// `pacerEngineDidRecompute`, relayed as `pacerViewEngineDidRecompute`.
    case engineRecompute = "engine recompute"
    /// `RateLimitWriteSignal.generation`, mirrored as `dashboardGeneration`.
    case rateLimitWrite = "rate-limit write"
    /// `LiveMeterBoard.values`, mirrored as `dashboardValues`.
    case liveMeter = "live meter"
    /// `AccountWriteSignal`, as `AccountList` (the window shell's title and
    /// its toolbar's account menu) reads it.
    case accountList = "account list"
    /// A dashboard view's own minute (or faster) clock loop, through
    /// `ViewRefreshGate.untilAwake()`.
    case minuteTick = "minute tick"
}

public extension Notification.Name {
    /// `pacerScanCycleDidComplete` for dashboard views: delivered at once
    /// while any display is awake, held while every display sleeps and then
    /// delivered once with the union of what changed. `object` is the
    /// original `ScanCycleSummary` (or nil) when passed straight through, and
    /// the merged summary after a hold. Data-path consumers (widgets, the
    /// API, alerts, the menu bar) keep observing the raw name.
    static let pacerViewScanCycleDidComplete = Notification.Name(
        "com.ericandrechek.pacer.view.scanCycleDidComplete")

    /// `pacerEngineDidRecompute` for dashboard views, gated the same way.
    static let pacerViewEngineDidRecompute = Notification.Name(
        "com.ericandrechek.pacer.view.engineDidRecompute")
}

public extension ScanCycleSummary {
    /// Everything changed, and nobody knows whose rate limits: what a held
    /// notification that carried no summary stands for. Consumers already
    /// treat a missing summary as "anything may have changed".
    static let everything = ScanCycleSummary(
        samplesChanged: true, rateLimitsChanged: true, projectAttributionChanged: true)

    /// Both summaries' changes. Whose rate limits moved survives only when
    /// every summary that wrote rate limits named the same account; two
    /// accounts, or one unknown, merge to nil ("any account"), which can only
    /// cause a read, never hide one.
    func merged(with other: ScanCycleSummary) -> ScanCycleSummary {
        let account: String?
        switch (rateLimitsChanged, other.rateLimitsChanged) {
        case (true, true):
            account = rateLimitAccountId == other.rateLimitAccountId ? rateLimitAccountId : nil
        case (true, false): account = rateLimitAccountId
        case (false, true): account = other.rateLimitAccountId
        case (false, false): account = nil
        }
        return ScanCycleSummary(
            samplesChanged: samplesChanged || other.samplesChanged,
            rateLimitsChanged: rateLimitsChanged || other.rateLimitsChanged,
            projectAttributionChanged: projectAttributionChanged || other.projectAttributionChanged,
            rateLimitAccountId: account)
    }
}

/// The bookkeeping half of `ViewRefreshGate`, as a value: which display state
/// we are in, and what is held. No clocks, no notifications, no main actor.
public struct ViewRefreshCoalescer: Sendable, Equatable {

    /// `unknown` until someone says; it passes everything through, as `awake`
    /// does. Only `asleep` holds.
    public enum Displays: Sendable, Equatable { case unknown, awake, asleep }

    /// What leaving `asleep` delivers.
    public struct Flush: Sendable, Equatable {
        /// Each distinct signal held, once, in the order it was first held.
        public let signals: [ViewRefreshSignal]
        /// Every held scan cycle's summary merged, when `.scanCycle` is held.
        public let scanSummary: ScanCycleSummary?
        /// How long the hold lasted.
        public let heldFor: TimeInterval
    }

    public private(set) var displays: Displays = .unknown
    public private(set) var held: [ViewRefreshSignal] = []
    public private(set) var heldScan: ScanCycleSummary?
    public private(set) var asleepSince: Date?

    public init() {}

    public var isHolding: Bool { displays == .asleep }

    /// Offer one firing of `signal`. True: deliver it now (any display awake,
    /// or nobody knows). False: it is held for the wake.
    ///
    /// `summary` is a scan cycle's; nil there means "unknown", which holds as
    /// `ScanCycleSummary.everything`.
    public mutating func offer(_ signal: ViewRefreshSignal, summary: ScanCycleSummary? = nil) -> Bool {
        guard isHolding else { return true }
        if !held.contains(signal) { held.append(signal) }
        if signal == .scanCycle {
            let incoming = summary ?? .everything
            heldScan = heldScan.map { $0.merged(with: incoming) } ?? incoming
        }
        return false
    }

    /// Move to `new`. Leaving `asleep` returns what to deliver (possibly
    /// nothing) and clears it; any other move returns nil.
    public mutating func setDisplays(_ new: Displays, now: Date) -> Flush? {
        let old = displays
        displays = new
        if new == .asleep {
            if old != .asleep { asleepSince = now }
            return nil
        }
        guard old == .asleep else { return nil }
        let flush = Flush(signals: held, scanSummary: heldScan,
                          heldFor: asleepSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        held = []
        heldScan = nil
        asleepSince = nil
        return flush
    }
}

/// Holds the dashboard window's refresh signals while every display is asleep
/// and delivers each once on wake. See the comment at the top of this file.
///
/// Fed by `MainThreadStallWatchdog`, which owns display-sleep detection
/// (`screensDidSleep`/`screensDidWake`, plus a seed at launch and a recheck on
/// display reconfiguration). Until it says anything the gate is `unknown` and
/// passes everything straight through, which is what every diagnostic launch
/// mode, test and headless render gets.
@MainActor
public final class ViewRefreshGate {

    public static let shared = ViewRefreshGate(center: .default)

    private var coalescer = ViewRefreshCoalescer()
    /// The latest delivery for each held signal. Every delivery is "show what
    /// is current now", so the latest one stands for every earlier one.
    private var deliveries: [ViewRefreshSignal: @MainActor (ScanCycleSummary?) -> Void] = [:]
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter: UInt64 = 0
    /// What the system last reported (`screensDidSleep` vs `screensDidWake`).
    /// Holding needs this *and* every online display confirming it.
    private var reportedAsleep = false
    private var recheck: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private let center: NotificationCenter
    private let allDisplaysAsleep: () -> Bool
    private let now: () -> Date
    private let log: (String) -> Void

    /// Rechecks after a sleep report that not every display confirmed yet:
    /// some may report asleep a moment after the notification.
    static let recheckDelays: [Duration] = [.seconds(2), .seconds(10), .seconds(60)]

    /// `allDisplaysAsleep` is asked whenever holding would start or continue;
    /// the app's is `DisplaySleepState.allDisplaysAsleepNow` (every online
    /// display, via CoreGraphics). Tests pass their own, and their own
    /// `center`, so nothing else listening is reached.
    public init(center: NotificationCenter,
                allDisplaysAsleep: @escaping () -> Bool = { DisplaySleepState.allDisplaysAsleepNow() },
                now: @escaping () -> Date = { Date() },
                log: @escaping (String) -> Void = { Log.write("ViewWork", $0) }) {
        self.center = center
        self.allDisplaysAsleep = allDisplaysAsleep
        self.now = now
        self.log = log
        observers = [
            center.addObserver(forName: .pacerScanCycleDidComplete, object: nil, queue: .main) { [weak self] note in
                let summary = note.object as? ScanCycleSummary
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let center = self.center
                    self.offer(.scanCycle, summary: summary) { merged in
                        center.post(name: .pacerViewScanCycleDidComplete, object: merged)
                    }
                }
            },
            center.addObserver(forName: .pacerEngineDidRecompute, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let center = self.center
                    self.offer(.engineRecompute) { _ in
                        center.post(name: .pacerViewEngineDidRecompute, object: nil)
                    }
                }
            },
        ]
    }

    // MARK: - Reading

    /// True while every display is asleep and dashboard refreshes are held.
    public var isHolding: Bool { coalescer.isHolding }

    /// The dashboard's view of the scan notification. Use in place of
    /// `NotificationCenter.default.publisher(for: .pacerScanCycleDidComplete)`
    /// in a view of the dashboard window; going through `shared` also makes
    /// sure the relay exists before the first post.
    public var scanCycles: NotificationCenter.Publisher {
        center.publisher(for: .pacerViewScanCycleDidComplete)
    }

    /// The dashboard's view of `pacerEngineDidRecompute`.
    public var engineRecomputes: NotificationCenter.Publisher {
        center.publisher(for: .pacerViewEngineDidRecompute)
    }

    // MARK: - Offering

    /// Deliver `signal` now through `deliver`, or hold it for the wake.
    ///
    /// While awake (or unknown) `deliver` runs synchronously, before this
    /// returns: no added latency. While holding, the latest `deliver` is kept
    /// and run once on wake with the merged summary (scan cycles) or nil.
    public func offer(_ signal: ViewRefreshSignal, summary: ScanCycleSummary? = nil,
                      deliver: @escaping @MainActor (ScanCycleSummary?) -> Void) {
        // A display that woke without telling us (a new one, Sidecar, a wake
        // the main thread missed while stuck): look before holding anything.
        if coalescer.isHolding, !allDisplaysAsleep() { setDisplays(.awake) }
        if coalescer.offer(signal, summary: summary) {
            deliver(summary)
        } else {
            deliveries[signal] = deliver
        }
    }

    /// Returns at once while any display is awake; while every display
    /// sleeps, suspends until one wakes. For a dashboard view's clock loop,
    /// after its sleep and before its work: the tick is held, and on wake the
    /// loop runs exactly once, at the real time, rather than catching up.
    /// Cancelling the caller's task resumes it.
    public func untilAwake() async {
        guard coalescer.isHolding else { return }
        if !allDisplaysAsleep() { setDisplays(.awake); return }
        _ = coalescer.offer(.minuteTick)
        nextWaiter &+= 1
        let id = nextWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || !coalescer.isHolding {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    // MARK: - Display state

    /// What the system reports: `screensDidSleep` (true), `screensDidWake`
    /// (false), or the launch seed. Asleep holds only once every online
    /// display confirms it; until then it stays awake and looks again a few
    /// times (`recheckDelays`).
    public func displaysReported(asleep: Bool) {
        reportedAsleep = asleep
        recheck?.cancel()
        recheck = nil
        if asleep {
            confirmAsleep(attempt: 0)
        } else {
            setDisplays(.awake)
        }
    }

    /// Something about the displays changed (one added or removed, Sidecar
    /// connected, a reconfiguration): decide again from what CoreGraphics says.
    public func displaysMayHaveChanged() {
        if reportedAsleep, allDisplaysAsleep() {
            setDisplays(.asleep)
        } else {
            setDisplays(.awake)
        }
    }

    private func confirmAsleep(attempt: Int) {
        if allDisplaysAsleep() {
            setDisplays(.asleep)
            return
        }
        if attempt == 0 {
            log("screens reported asleep, but a display is still awake — not holding")
        }
        setDisplays(.awake)
        guard attempt < Self.recheckDelays.count else { return }
        let delay = Self.recheckDelays[attempt]
        recheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.reportedAsleep else { return }
            self.confirmAsleep(attempt: attempt + 1)
        }
    }

    private func setDisplays(_ new: ViewRefreshCoalescer.Displays) {
        let wasHolding = coalescer.isHolding
        guard let flush = coalescer.setDisplays(new, now: now()) else {
            if new == .asleep, !wasHolding {
                log("displays asleep — holding view refreshes")
            }
            return
        }
        // Delivered before anything else runs on main, so the first frame
        // after wake is drawn from current state.
        let ticks = waiters.count
        var names: [String] = []
        for signal in flush.signals {
            if signal == .minuteTick {
                names.append(ticks > 1 ? "\(signal.rawValue) ×\(ticks)" : signal.rawValue)
                continue
            }
            names.append(signal.rawValue)
            let summary = signal == .scanCycle ? flush.scanSummary : nil
            deliveries.removeValue(forKey: signal)?(summary)
        }
        deliveries.removeAll()
        let resumed = waiters
        waiters.removeAll()
        for continuation in resumed.values { continuation.resume() }
        let count = flush.signals.count
        log("displays awake — delivered \(count) held signal(s)"
            + (names.isEmpty ? "" : ": " + names.joined(separator: ", "))
            + " · held \(Self.duration(flush.heldFor))")
    }

    /// "42s", "12m 5s", "6h 3m".
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
