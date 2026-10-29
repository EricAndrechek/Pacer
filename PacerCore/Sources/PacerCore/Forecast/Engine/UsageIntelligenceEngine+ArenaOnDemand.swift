import Foundation

// The compare sheet lists every model for a meter and draws the ones toggled
// on. The window's fit already projects the engine's methods, the pick and the
// few best-recorded arena models; any other toggled on is made here: its live
// projection is made once, on demand, at the live lane's priority, through the
// same forecaster and cache as the drawn ones (`ArenaLiveForecaster.makeNow`),
// and drawn beside them until it is toggled off or the sheet closes. Nothing
// is persisted; the selection is the sheet's (`ArenaExtraLines`).

/// What a window can draw now for models toggled on that its fit does not
/// project.
public struct ArenaOnDemand: Sendable {
    public enum Line: Sendable {
        /// Its projection is in the cache for this cycle: the line, built as
        /// the drawn rows' are.
        case drawn(BurnTrajectory.ScoredTrajectory)
        /// Its last attempt failed, and why ("downloading", "no forecast
        /// this cycle").
        case failed(String)
        /// Neither: nothing made for this cycle recently enough.
        case missing
    }

    public let account: String?
    public let windowKey: String
    public let lines: [String: Line]
    /// Makes the listed models' projections now and returns once they are in
    /// the cache (or their failures are). Nil without the runtime or a live
    /// cycle to project.
    public let make: (@Sendable ([String]) async -> Void)?

    /// The selection a sheet holds for this answer (`ArenaExtraLines.key`).
    public var key: String { ArenaExtraLines.key(account: account, windowKey: windowKey) }

    public init(account: String?, windowKey: String, lines: [String: Line],
                make: (@Sendable ([String]) async -> Void)?) {
        self.account = account; self.windowKey = windowKey; self.lines = lines; self.make = make
    }
}

extension UsageIntelligenceEngine {

    /// The lines `models` can draw on `windowKey` now, and a way to make the
    /// ones that can't (`ArenaOnDemand`). Reads the cache only; never runs a
    /// model. `live` as for `rateLimitTrajectories`, so the lines start where
    /// the drawn ones do.
    public func arenaOnDemand(windowKey key: String, models: [String],
                              live: LiveMeterValue? = nil) -> ArenaOnDemand {
        let missing = ArenaOnDemand(account: scope.accountId, windowKey: key,
                                    lines: Dictionary(models.map { ($0, .missing) }, uniquingKeysWith: { a, _ in a }),
                                    make: nil)
        guard let arena, let f = features, let account = scope.accountId,
              let window = f.windows.first(where: { $0.key == key }),
              let binding = ArenaWindowBinding.make(account: account, window: window),
              let samples = f.rateLimit[key] else { return missing }
        let (currentOpt, _) = BurnTrajectory.segment(samples: samples, duration: window.duration, now: f.now)
        guard let current = currentOpt?.withLive(live, duration: window.duration), current.resetsAt > f.now
        else { return missing }

        let specs = Dictionary(arena.roster.specs(for: binding.target).map { ($0.name, $0) },
                               uniquingKeysWith: { a, _ in a })
        let accuracy = selfEvalAccuracy(surface: EngineSelfEval.rlSurface(key))
        var lines: [String: ArenaOnDemand.Line] = [:]
        for id in models {
            guard let spec = specs[id] else { lines[id] = .missing; continue }
            let model = ArenaCachedBurnModel(spec: spec, binding: binding, cache: arena.cache)
            if let line = Self.scoredTrajectory(model, f, current: current, sampleCount: 48,
                                                stat: accuracy?.methods.first { $0.method == id }, isSelected: false) {
                lines[id] = .drawn(line)
            } else if let reason = arena.cache.failure(model.key) {
                lines[id] = .failed(reason)
            } else {
                lines[id] = .missing
            }
        }

        let make: (@Sendable ([String]) async -> Void)? = arena.makeLive.map { makeLive in
            // Cut where this fit's lines start, so the cache serves the
            // projection to this cycle (`ArenaLiveRequest.cutAt`).
            let resetsAt = current.resetsAt, latest = current.samples.last?.at ?? f.now, cutAt = f.now
            let known = Set(specs.keys)
            return { ids in
                let wanted = ids.filter { known.contains($0) }
                guard !wanted.isEmpty else { return }
                await makeLive(ArenaLiveRequest(binding: binding, resetsAt: resetsAt, latestReadingAt: latest,
                                                models: wanted, cutAt: cutAt))
            }
        }
        return ArenaOnDemand(account: account, windowKey: key, lines: lines, make: make)
    }
}

/// The models a compare sheet was asked to draw that its window does not
/// project itself, and where each stands. A value the sheet holds in `@State` for as long as it is open:
/// never persisted, emptied when the sheet's window or account changes
/// (`follow`), and any answer for another key is dropped (`apply`), so an old
/// account's projection never lands on the new one's chart.
public struct ArenaExtraLines: Sendable {
    /// Lines drawn this way at once, at most: the sheet's cap on every line
    /// (`ModelBoardList.lineCap`), so this share of them never refuses one
    /// the sheet has room for.
    public static let cap = 10

    public enum State: Sendable, Equatable {
        case computing
        case drawn
        case failed(String)
    }

    /// Whether a model's projection has been asked for since it was
    /// selected or last drawn: asked once, not again until a line has gone
    /// stale or the model is selected again.
    private enum Ask: Sendable { case none, inFlight, answered }

    private struct Entry: Sendable {
        var state: State = .computing
        var line: BurnTrajectory.ScoredTrajectory?
        var ask: Ask = .none
        /// The drawn line has aged out of the cache: made again, and drawn
        /// until the new one lands.
        var stale = false
    }

    public static func key(account: String?, windowKey: String) -> String { "\(account ?? "")|\(windowKey)" }

    /// The window and account the selection belongs to.
    public private(set) var key: String
    /// Selected models, in the order they were clicked.
    public private(set) var ids: [String] = []
    private var entries: [String: Entry] = [:]

    public init(key: String = "") { self.key = key }

    public var isFull: Bool { ids.count >= Self.cap }
    public func contains(_ id: String) -> Bool { entries[id] != nil }
    public func state(_ id: String) -> State? { entries[id]?.state }
    /// The drawn lines, in click order.
    public var lines: [BurnTrajectory.ScoredTrajectory] { ids.compactMap { entries[$0]?.line } }

    /// Start over when the sheet now shows another window or account.
    public mutating func follow(key: String) {
        guard key != self.key else { return }
        self = ArenaExtraLines(key: key)
    }

    /// Select or deselect. Returns whether the model is now selected; false
    /// too when the cap refuses it.
    @discardableResult
    public mutating func toggle(_ id: String) -> Bool {
        if entries[id] != nil {
            entries[id] = nil
            ids.removeAll { $0 == id }
            return false
        }
        guard !isFull else { return false }
        entries[id] = Entry()
        ids.append(id)
        return true
    }

    /// Select exactly `wanted`: a model no longer in it is dropped (an
    /// answer still on its way for it is ignored), a new one starts
    /// computing, and the rest keep their lines and asks. The sheet calls this
    /// with the lines it wants that the window does not draw itself.
    public mutating func sync(_ wanted: [String]) {
        remove(Set(ids).subtracting(wanted))
        for id in wanted where entries[id] == nil && !isFull {
            entries[id] = Entry()
            ids.append(id)
        }
    }

    /// Forget models that need no line from here (the window now draws them).
    public mutating func remove(_ drop: Set<String>) {
        ids.removeAll { drop.contains($0) }
        for id in drop { entries[id] = nil }
    }

    /// Fold an answer in. Returns false, changing nothing, when it is for
    /// another window or account than the selection's.
    @discardableResult
    public mutating func apply(_ answer: ArenaOnDemand) -> Bool {
        guard answer.key == key else { return false }
        for id in ids {
            guard var e = entries[id], let line = answer.lines[id] else { continue }
            switch (line, e.ask) {
            case let (.drawn(t), _):
                e.line = t; e.state = .drawn; e.ask = .none; e.stale = false
            case (_, .inFlight):
                break
            case let (.failed(reason), .answered):
                e.line = nil; e.state = .failed(reason)
            case (.missing, .answered):
                e.line = nil; e.state = .failed(Self.noForecast)
            case (.failed, .none), (.missing, .none):
                // To be asked: a stale line stays drawn until its next one.
                e.stale = e.line != nil
                e.state = e.line == nil ? .computing : .drawn
            }
            entries[id] = e
        }
        return true
    }

    /// The selected models to make now, marked as asked: each without a
    /// current line that has not been asked since it was selected or last
    /// drawn.
    public mutating func takeToMake() -> [String] {
        var out: [String] = []
        for id in ids {
            guard var e = entries[id], e.ask == .none, e.line == nil || e.stale else { continue }
            e.ask = .inFlight
            entries[id] = e
            out.append(id)
        }
        return out
    }

    /// The `make` for `made` has returned. Returns false when the selection
    /// has since moved to another key (the answer that follows is dropped).
    @discardableResult
    public mutating func finished(_ made: [String], key: String) -> Bool {
        guard key == self.key else { return false }
        for id in made where entries[id]?.ask == .inFlight { entries[id]?.ask = .answered }
        return true
    }

    /// What a model with nothing in the cache after it was made says: the
    /// forecaster's own words for a model that gave no forecast.
    public static let noForecast = "no forecast this cycle"
}
