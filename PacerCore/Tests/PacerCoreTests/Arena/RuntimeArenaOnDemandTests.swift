import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// Drawing a model picked from the compare sheet's "More models"
/// (`UsageIntelligenceEngine.arenaOnDemand`, `ArenaLiveForecaster.makeNow`,
/// `ArenaExtraLines`): a projection already in the cache draws at once; a miss
/// is made once, at live priority, then draws; a failure says why; an answer
/// for a window or account the sheet has left is dropped.
@Suite("Arena runtime: drawing a model on demand", .serialized)
struct RuntimeArenaOnDemandTests {

    typealias Fixtures = RuntimeEngineTests

    /// The peeker, counting its forecasts.
    final class Counted: ArenaModel {
        nonisolated(unsafe) static var forecasts = 0
        static let lock = NSLock()
        let inner: Fixtures.Peeker
        init(context: ArenaContext) { inner = Fixtures.Peeker(context: context) }
        func fit(_ history: ArenaHistory) { inner.fit(history) }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            Self.lock.lock(); Self.forecasts += 1; Self.lock.unlock()
            return try inner.forecast(request)
        }
        static var count: Int { lock.lock(); defer { lock.unlock() }; return forecasts }
    }
    static let counted = ArenaModelSpec(name: "test-counted", targets: Fixtures.meters) { Counted(context: $0) }
    static let pinned = ArenaModelSpec(name: "test-pinned", targets: Fixtures.meters, weights: ["acme/net@abc"]) {
        Fixtures.Peeker(context: $0)
    }

    static let key = ArenaExtraLines.key(account: Fixtures.account, windowKey: "five_hour")

    /// Counts the link's on-demand asks.
    final class Asks: @unchecked Sendable {
        let lock = NSLock()
        var made: [[String]] = []
        func add(_ r: ArenaLiveRequest) { lock.lock(); made.append(r.models); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return made }
    }

    /// A projection for the seeded live cycle already in the cache: the
    /// answer draws it, built like the drawn rows, and nothing is made.
    @Test func aCacheHitDrawsAtOnce() async throws {
        let container = try Fixtures.seeded()
        let engine = await Fixtures.engine(container)
        let cache = ArenaLiveCache()
        let asks = Asks()
        let link = ArenaEngineLink(roster: ArenaRoster(registry: [Self.counted]), cache: cache,
                                   requestLive: { _ in }, makeLive: { asks.add($0) })
        await engine.adopt(arena: link)
        await engine.recompute(now: Fixtures.now)
        let reset = Fixtures.now.addingTimeInterval(3 * 3600)
        let grid = stride(from: 0, through: 36, by: 1).map { ArenaTime.millis(Fixtures.now) + Millis($0) * 5 * ArenaTime.minute }
        let projection = try #require(ArenaProjection(grid: grid, median: grid.indices.map { 30 + Double($0) }))
        cache.store(.init(resetsAt: reset, asOf: Fixtures.now, projection: projection),
                    for: .init(account: Fixtures.account, windowKey: "five_hour", model: Self.counted.name))

        var extras = ArenaExtraLines(key: Self.key)
        let r1 = extras.toggle(Self.counted.name)
        #expect(r1)
        let answer = await engine.arenaOnDemand(windowKey: "five_hour", models: extras.ids)
        guard case let .drawn(line)? = answer.lines[Self.counted.name] else {
            Issue.record("expected a line, got \(String(describing: answer.lines[Self.counted.name]))"); return
        }
        #expect(line.canProject && !line.isSelected && line.trajectory.points.count > 2)
        let r2 = extras.apply(answer)
        #expect(r2)
        #expect(extras.state(Self.counted.name) == .drawn)
        #expect(extras.lines.map(\.modelId) == [Self.counted.name])
        let r3 = extras.takeToMake()
        #expect(r3.isEmpty)
        #expect(asks.all.isEmpty)
    }

    /// Not in the cache: the sheet says it is computing, the model is made
    /// once through the live forecaster, then drawn; asking again draws it
    /// without running it, and making it again is a cache hit.
    @Test func aMissIsMadeOnceThenDrawn() async throws {
        let container = try Fixtures.seeded()
        let engine = await Fixtures.engine(container)
        let rt = Fixtures.runtime(container, roster: [Self.counted])
        await engine.adopt(arena: rt.link)
        await engine.recompute(now: Fixtures.now)
        // No record: the refit asks for nothing.
        #expect(await engine.arenaModelIds(windowKey: "five_hour").isEmpty)
        Counted.forecasts = 0

        var extras = ArenaExtraLines(key: Self.key)
        extras.toggle(Self.counted.name)
        let first = await engine.arenaOnDemand(windowKey: "five_hour", models: extras.ids)
        guard case .missing? = first.lines[Self.counted.name] else { Issue.record("expected a miss"); return }
        let r4 = extras.apply(first)
        #expect(r4)
        #expect(extras.state(Self.counted.name) == .computing)
        let todo = extras.takeToMake()
        #expect(todo == [Self.counted.name])
        // Taken once: a second refresh while it is made asks for nothing.
        let r5 = extras.takeToMake()
        #expect(r5.isEmpty)
        let make = try #require(first.make)
        await make(todo)
        #expect(Counted.count == 1)
        let r6 = extras.finished(todo, key: Self.key)
        #expect(r6)

        let second = await engine.arenaOnDemand(windowKey: "five_hour", models: extras.ids)
        let r7 = extras.apply(second)
        #expect(r7)
        #expect(extras.state(Self.counted.name) == .drawn)
        #expect(extras.lines.first?.trajectory.points.first?.usedPercentage
            == second.lines[Self.counted.name].flatMap { if case let .drawn(t) = $0 { t } else { nil } }?
                .trajectory.points.first?.usedPercentage)
        let r8 = extras.takeToMake()
        #expect(r8.isEmpty)
        await make([Self.counted.name])
        #expect(Counted.count == 1)
    }

    /// A model that throws, or whose weights are not here, says why in the
    /// forecaster's words once it has been made, and is not asked again.
    @Test func aFailureSaysWhy() async throws {
        let container = try Fixtures.seeded()
        let engine = await Fixtures.engine(container)
        let rt = Fixtures.runtime(container, roster: [Fixtures.bomb, Self.pinned])
        await engine.adopt(arena: rt.link)
        await engine.recompute(now: Fixtures.now)
        var extras = ArenaExtraLines(key: Self.key)
        extras.toggle(Fixtures.bomb.name)
        extras.toggle(Self.pinned.name)
        let first = await engine.arenaOnDemand(windowKey: "five_hour", models: extras.ids)
        extras.apply(first)
        let todo = extras.takeToMake()
        #expect(Set(todo) == [Fixtures.bomb.name, Self.pinned.name])
        await first.make?(todo)
        extras.finished(todo, key: Self.key)
        extras.apply(await engine.arenaOnDemand(windowKey: "five_hour", models: extras.ids))
        #expect(extras.state(Fixtures.bomb.name) == .failed(ArenaExtraLines.noForecast))
        #expect(extras.state(Self.pinned.name) == .failed("downloading"))
        #expect(extras.lines.isEmpty)
        let r9 = extras.takeToMake()
        #expect(r9.isEmpty)
    }

    /// The sheet moved to another window or account while a model was being
    /// made: the selection starts over, and the late answer is dropped.
    @Test func aScopeChangeDropsAStaleAnswer() async throws {
        let container = try Fixtures.seeded()
        let engine = await Fixtures.engine(container)
        let rt = Fixtures.runtime(container, roster: [Self.counted])
        await engine.adopt(arena: rt.link)
        await engine.recompute(now: Fixtures.now)

        var extras = ArenaExtraLines(key: Self.key)
        extras.toggle(Self.counted.name)
        let first = await engine.arenaOnDemand(windowKey: "five_hour", models: extras.ids)
        extras.apply(first)
        let todo = extras.takeToMake()
        // Another account's sheet now.
        extras.follow(key: ArenaExtraLines.key(account: "acct-other", windowKey: "five_hour"))
        #expect(extras.ids.isEmpty)
        await first.make?(todo)
        let r10 = extras.finished(todo, key: Self.key)
        #expect(!r10)
        let late = await engine.arenaOnDemand(windowKey: "five_hour", models: [Self.counted.name])
        guard case .drawn? = late.lines[Self.counted.name] else { Issue.record("expected the late line"); return }
        let r11 = extras.apply(late)
        #expect(!r11)
        #expect(extras.lines.isEmpty && extras.state(Self.counted.name) == nil)
        // Same account, another window: dropped too.
        var weekly = ArenaExtraLines(key: ArenaExtraLines.key(account: Fixtures.account, windowKey: "seven_day"))
        weekly.toggle(Self.counted.name)
        let r12 = weekly.apply(late)
        #expect(!r12)
        #expect(weekly.state(Self.counted.name) == .computing)
        // Following the same key keeps the selection.
        weekly.follow(key: weekly.key)
        #expect(weekly.ids == [Self.counted.name])
    }

    /// At most `cap` at once; deselecting frees a place; a model the window
    /// now draws itself leaves the selection.
    @Test func theCapAndDeselecting() {
        var extras = ArenaExtraLines(key: Self.key)
        for i in 0..<ArenaExtraLines.cap { let on = extras.toggle("m\(i)"); #expect(on) }
        #expect(extras.isFull)
        let r13 = extras.toggle("m-extra")
        #expect(!r13)
        #expect(!extras.contains("m-extra"))
        let r14 = extras.toggle("m0")
        #expect(!r14)
        #expect(!extras.isFull)
        let r15 = extras.toggle("m-extra")
        #expect(r15)
        extras.remove(["m1", "m2"])
        #expect(extras.ids == ["m3", "m4", "m5", "m-extra"])
    }
}
