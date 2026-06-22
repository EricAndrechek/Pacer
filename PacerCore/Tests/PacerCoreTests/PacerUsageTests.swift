import Foundation
import Testing
@testable import PacerCore

@Suite("Pacer usage history API")
struct PacerUsageTests {

    private func row(date: String, model: String, inProgress: Bool) -> PacerDailyUsage.Row {
        PacerDailyUsage.Row(date: date, model: model, input: 100, output: 200, cacheRead: 300,
                            cacheCreation5m: 10, cacheCreation1h: 5, costUSD: 1.25, inProgress: inProgress)
    }

    @Test func dailyEncodesAllFiveCategoriesAndInProgressFlag() throws {
        let usage = PacerDailyUsage(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            today: "2026-06-22",
            rows: [row(date: "2026-06-21", model: "claude-opus-4-8", inProgress: false),
                   row(date: "2026-06-22", model: "claude-opus-4-8", inProgress: true)])
        let json = try usage.encodedJSON()
        #expect(json.contains("\"cacheCreation5m\" : 10"))
        #expect(json.contains("\"cacheCreation1h\" : 5"))
        #expect(json.contains("\"inProgress\" : true"))
        #expect(json.contains("\"inProgress\" : false"))
        #expect(json.contains("\"today\" : \"2026-06-22\""))
    }

    @Test func modelsEncodeLifetimeRow() throws {
        let usage = PacerModelUsage(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            models: [PacerModelUsage.Row(model: "claude-opus-4-8", input: 1000, output: 2000,
                                         cacheRead: 3000, cacheCreation5m: 100, cacheCreation1h: 50,
                                         costUSD: 42.5, firstDate: "2026-01-01", lastDate: "2026-06-22")])
        let json = try usage.encodedJSON()
        #expect(json.contains("\"model\" : \"claude-opus-4-8\""))
        #expect(json.contains("\"firstDate\" : \"2026-01-01\""))
        #expect(json.contains("\"costUSD\" : 42.5"))
    }

    @Test func metricsEmitPerModelSeriesWhenTodayModelsProvided() {
        let snapshot = PacerSnapshotPayload(
            schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            limits: .init(fiveHour: nil, sevenDay: nil),
            cost: .init(todayUSD: 0, weekUSD: 0, monthUSD: 0, allTimeUSD: 0,
                        projectedTodayUSD: nil, projectedTodayLowUSD: nil, projectedTodayHighUSD: nil,
                        projectedMonthUSD: nil, projectedMonthLowUSD: nil, projectedMonthHighUSD: nil),
            tokens: .init(todayInput: 0, todayOutput: 0, todayCacheRead: 0, todayTotal: 0),
            pace: .init(percentile: nil, status: nil),
            session: nil, overageUSD: 0,
            dataSource: .init(source: nil, lastSampleAt: nil, ageSeconds: nil, forecastFresh: false))
        let text = PacerMetrics(snapshot: snapshot,
                                todayModels: [row(date: "2026-06-22", model: "claude-opus-4-8", inProgress: true)],
                                version: "1.0", build: "1").prometheusText()
        #expect(text.contains("pacer_model_cost_usd{model=\"claude-opus-4-8\"} 1.25"))
        #expect(text.contains("pacer_model_tokens{model=\"claude-opus-4-8\",kind=\"input\"} 100"))
    }
}
