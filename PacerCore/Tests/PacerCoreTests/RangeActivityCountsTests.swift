import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// History's Projects and Sessions tiles: counted from the project-day and
/// session rollups for a range, all accounts or one. Expressions are short
/// with typed intermediates — long mixed-literal ones time out Xcode 16's
/// type checker on the macOS 15 runner.
@MainActor
struct RangeActivityCountsTests {

    private let calendar = Calendar.current

    /// Noon on 2026-10-`day`, local time.
    private func noon(_ day: Int) -> Date {
        let c = DateComponents(year: 2026, month: 10, day: day, hour: 12)
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    private func dayKey(_ day: Int) -> String {
        TokenSample.formatDate(noon(day))
    }

    private func projectDay(_ path: String, _ day: Int) -> ProjectDailyAggregate {
        ProjectDailyAggregate(projectPath: path, date: dayKey(day))
    }

    private func accountProjectDay(_ account: String, _ path: String, _ day: Int) -> AccountProjectDailyAggregate {
        AccountProjectDailyAggregate(
            accountId: account, projectPath: path, date: dayKey(day),
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            totalCostUSD: 0, sessionCount: 0, modelCount: 0,
            lastActive: noon(day), sessionIdsJSON: Data(), modelBreakdownJSON: nil)
    }

    private func session(_ id: String, first: Int, last: Date) -> SessionInfo {
        SessionInfo(sessionId: id, firstSeenAt: noon(first), lastSeenAt: last, projectPath: "/p")
    }

    private func accountSession(_ account: String, _ id: String, last: Date) -> AccountSessionInfo {
        AccountSessionInfo(
            accountId: account, sessionId: id,
            firstSeenAt: last, lastSeenAt: last, projectPath: "/p",
            ccVersion: nil, cumulativeCostUSD: 0,
            cumulativeInputTokens: 0, cumulativeOutputTokens: 0,
            cumulativeCacheReadTokens: 0,
            cumulativeCacheCreation5mTokens: 0,
            cumulativeCacheCreation1hTokens: 0,
            topModel: "")
    }

    private func store() throws -> ModelContext {
        let container = try PacerStore.makeInMemoryContainer()
        return ModelContext(container)
    }

    // MARK: Projects

    @Test func projectsCountsEachPathOnceAcrossItsDays() throws {
        let context = try store()
        context.insert(projectDay("/a", 10))
        context.insert(projectDay("/a", 11))
        context.insert(projectDay("/b", 11))
        context.insert(projectDay(ProjectDailyAggregate.unknownProjectPath, 12))
        try context.save()
        let all: Int = RangeActivityCounts.projects(context, since: nil, accountId: nil)
        #expect(all == 3)
        let rows: Int = RangeActivityCounts.projectDays(context, since: nil, accountId: nil)
        #expect(rows == 4)
    }

    @Test func projectsInARangeTakeItsWholeFirstDay() throws {
        let context = try store()
        context.insert(projectDay("/old", 9))
        context.insert(projectDay("/edge", 10))
        context.insert(projectDay("/new", 12))
        try context.save()
        // `since` late on the 10th still takes the 10th, as the daily cards do.
        let late: Date = noon(10).addingTimeInterval(6 * 3600)
        let inRange: Int = RangeActivityCounts.projects(context, since: late, accountId: nil)
        #expect(inRange == 2)
        let rows: Int = RangeActivityCounts.projectDays(context, since: late, accountId: nil)
        #expect(rows == 2)
    }

    @Test func projectsForOneAccountReadOnlyItsRows() throws {
        let context = try store()
        context.insert(accountProjectDay("acct-a", "/a", 10))
        context.insert(accountProjectDay("acct-a", "/b", 11))
        context.insert(accountProjectDay("acct-b", "/c", 11))
        context.insert(accountProjectDay("acct-a", "/old", 2))
        try context.save()
        let a: Int = RangeActivityCounts.projects(context, since: noon(10), accountId: "acct-a")
        #expect(a == 2)
        let aAll: Int = RangeActivityCounts.projects(context, since: nil, accountId: "acct-a")
        #expect(aAll == 3)
        let b: Int = RangeActivityCounts.projectDays(context, since: nil, accountId: "acct-b")
        #expect(b == 1)
        // The global tables are another scope: empty here.
        let global: Int = RangeActivityCounts.projects(context, since: nil, accountId: nil)
        #expect(global == 0)
    }

    // MARK: Sessions

    @Test func sessionsCountThoseActiveInTheRange() throws {
        let context = try store()
        context.insert(session("ended-before", first: 5, last: noon(8)))
        // Started before the range, still going in it: counted.
        context.insert(session("spans-in", first: 8, last: noon(10)))
        // Early on the first day, before `since`'s time of day: counted.
        let early: Date = calendar.startOfDay(for: noon(10)).addingTimeInterval(60)
        context.insert(session("early-first-day", first: 10, last: early))
        context.insert(session("recent", first: 12, last: noon(12)))
        try context.save()
        let since: Date = noon(10).addingTimeInterval(3600)
        let inRange: Int = RangeActivityCounts.sessions(context, since: since, accountId: nil)
        #expect(inRange == 3)
        let all: Int = RangeActivityCounts.sessions(context, since: nil, accountId: nil)
        #expect(all == 4)
    }

    @Test func sessionsForOneAccountReadOnlyItsRows() throws {
        let context = try store()
        context.insert(accountSession("acct-a", "s1", last: noon(10)))
        context.insert(accountSession("acct-a", "s2", last: noon(3)))
        context.insert(accountSession("acct-b", "s3", last: noon(10)))
        try context.save()
        let a: Int = RangeActivityCounts.sessions(context, since: noon(9), accountId: "acct-a")
        #expect(a == 1)
        let aAll: Int = RangeActivityCounts.sessions(context, since: nil, accountId: "acct-a")
        #expect(aAll == 2)
        let global: Int = RangeActivityCounts.sessions(context, since: nil, accountId: nil)
        #expect(global == 0)
    }

    @Test func anEmptyStoreCountsNothing() throws {
        let context = try store()
        let projects: Int = RangeActivityCounts.projects(context, since: noon(1), accountId: nil)
        let sessions: Int = RangeActivityCounts.sessions(context, since: noon(1), accountId: "acct")
        #expect(projects == 0)
        #expect(sessions == 0)
    }

    @Test func dayStartIsTheStartOfSincesDay() {
        let start: Date? = RangeActivityCounts.dayStart(noon(10))
        let expected: Date = calendar.startOfDay(for: noon(10))
        #expect(start == expected)
        #expect(RangeActivityCounts.dayStart(nil) == nil)
    }
}
