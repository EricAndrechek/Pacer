import Foundation
import Testing
@testable import PacerCore

@Suite("Accounts over the HTTP API")
struct PacerAccountsAPITests {

    private func row(id: String, label: String, displayName: String,
                     organizationName: String? = nil, active: Bool = false,
                     unattributed: Bool = false,
                     cost: Double = 0) -> PacerAccountList.Row {
        PacerAccountList.Row(
            id: id, label: label, displayName: displayName,
            organizationName: organizationName, subscriptionType: "max20x",
            isActive: active, unattributed: unattributed,
            firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_100_000),
            usage: PacerAccountList.Usage(
                input: 10, output: 20, cacheRead: 30, cacheCreation5m: 4,
                cacheCreation1h: 2, costUSD: cost,
                firstDate: "2026-01-01", lastDate: "2026-09-04"),
            limits: PacerAccountList.Limits(
                fiveHourPercent: 42, fiveHourResetsAt: nil,
                sevenDayPercent: 11, sevenDayResetsAt: nil,
                overageUSD: 1.5, polledAt: nil))
    }

    private func usageRow(model: String, cost: Double,
                          input: Int = 100, output: Int = 200,
                          cacheRead: Int = 300) -> PacerDailyUsage.Row {
        PacerDailyUsage.Row(date: "2026-09-04", model: model, input: input, output: output,
                            cacheRead: cacheRead, cacheCreation5m: 0, cacheCreation1h: 0,
                            costUSD: cost, inProgress: true)
    }

    // MARK: - The list payload

    @Test func listEncodesIdentityUsageAndLimits() throws {
        let list = PacerAccountList(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            activeAccountId: "org-work",
            accounts: [row(id: "org-work", label: "eng@example.com",
                           displayName: "Claude account (max20x)",
                           organizationName: "Acme", active: true, cost: 70.78)])
        let json = try list.encodedJSON()
        #expect(json.contains("\"activeAccountId\" : \"org-work\""))
        #expect(json.contains("\"organizationName\" : \"Acme\""))
        #expect(json.contains("\"costUSD\" : 70.78"))
        #expect(json.contains("\"fiveHourPercent\" : 42"))
    }

    /// The unattributed bucket is a row, not a hidden remainder: a consumer
    /// summing the array has to land on `/v1/usage/daily`'s global total.
    @Test func unattributedIsCarriedAsARowSoTheSumIsWhole() throws {
        let list = PacerAccountList(
            schemaVersion: 1, generatedAt: Date(), activeAccountId: "org-work",
            accounts: [row(id: "org-work", label: "w", displayName: "w", active: true, cost: 70),
                       row(id: "org-home", label: "h", displayName: "h", cost: 30),
                       row(id: PacerAccountsBuilder.unattributedAlias, label: "Unattributed",
                           displayName: "Unattributed", unattributed: true, cost: 5)])
        let total = list.accounts.compactMap(\.usage).reduce(0) { $0 + $1.costUSD }
        #expect(total == 105)
        #expect(list.accounts.filter(\.unattributed).count == 1)
    }

    /// The alias exists because the rollup's own key starts with U+0000, to be
    /// impossible to type — which also makes it impossible to send.
    @Test func unattributedAliasIsURLSafeUnlikeTheRollupKey() {
        #expect(PacerAccountsBuilder.unattributedAlias == "unattributed")
        #expect(AccountDailyAggregate.unattributedKey.contains("\u{0000}"))
        #expect(PacerAccountsBuilder.unattributedAlias
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            == PacerAccountsBuilder.unattributedAlias)
    }

    @Test func unknownAccountCarriesTheLegalValues() {
        let error = PacerAccountsBuilder.ResolveError.unknownAccount(known: ["org-work", "unattributed"])
        guard case .unknownAccount(let known) = error else { return #expect(Bool(false)) }
        #expect(known == ["org-work", "unattributed"])
    }

    // MARK: - The scoped usage payloads

    @Test func scopedPayloadsEchoTheAccountAndUnscopedOnesOmitIt() throws {
        let scoped = PacerDailyUsage(
            schemaVersion: 1, generatedAt: Date(), account: "org-work",
            today: "2026-09-04", rows: [usageRow(model: "claude-opus-5", cost: 1)])
        #expect(try scoped.encodedJSON().contains("\"account\" : \"org-work\""))

        let global = PacerDailyUsage(
            schemaVersion: 1, generatedAt: Date(), account: nil,
            today: "2026-09-04", rows: [usageRow(model: "claude-opus-5", cost: 1)])
        #expect(!(try global.encodedJSON().contains("\"account\"")))

        let models = PacerModelUsage(
            schemaVersion: 1, generatedAt: Date(), account: "org-home", models: [])
        #expect(try models.encodedJSON().contains("\"account\" : \"org-home\""))
    }

    // MARK: - Prometheus

    @Test func perAccountSeriesUseTheIdAndNeverTheEmailLabel() {
        let text = metrics(accounts: [
            PacerMetrics.AccountToday(
                account: row(id: "org-work", label: "eng@example.com",
                             displayName: "Claude account (max20x)",
                             organizationName: "Globex", active: true),
                models: [usageRow(model: "claude-opus-5", cost: 2.5)]),
            PacerMetrics.AccountToday(
                account: row(id: "org-home", label: "me@example.com",
                             displayName: "Claude account (max20x)"),
                models: [usageRow(model: "claude-opus-5", cost: 0.25)]),
        ])
        #expect(text.contains("pacer_account_cost_usd{account=\"org-work\"} 2.5"))
        #expect(text.contains("pacer_account_tokens{account=\"org-home\",kind=\"output\"} 200"))
        #expect(text.contains("account=\"org-work\",name=\"Globex\",active=\"true\""))
        // The display label may be an email; a scraped endpoint must not carry one.
        #expect(!text.contains("@example.com"))
    }

    /// A single-account install would emit the same numbers twice under a
    /// different name, so it emits none.
    @Test func perAccountSeriesAreOmittedWithOneAccount() {
        let text = metrics(accounts: [
            PacerMetrics.AccountToday(
                account: row(id: "org-work", label: "w", displayName: "w", active: true),
                models: [usageRow(model: "claude-opus-5", cost: 2.5)]),
        ])
        #expect(!text.contains("pacer_account_cost_usd"))
        #expect(!text.contains("pacer_account_info"))
    }

    /// A name the user typed is published verbatim — it is the only readable
    /// label available, and they chose it.
    @Test func infoSeriesPublishesADeliberateRename() {
        let text = metrics(accounts: [
            PacerMetrics.AccountToday(
                account: row(id: "a", label: "someone@example.com", displayName: "Work"),
                models: []),
            PacerMetrics.AccountToday(
                account: row(id: "b", label: "other@example.com", displayName: "Personal"),
                models: []),
        ])
        #expect(text.contains("account=\"a\",name=\"Work\""))
        #expect(text.contains("account=\"b\",name=\"Personal\""))
    }

    /// The case that actually happens: Anthropic derives the org name from the
    /// account's email, so `organizationName` is
    /// `"<someone>@<domain>'s Organization"` and nothing observed is safe to
    /// scrape. Caught live — the first version of this shipped the address.
    @Test func infoSeriesNeverPublishesAnEmailDerivedOrgName() {
        let text = metrics(accounts: [
            PacerMetrics.AccountToday(
                account: row(id: "0000-1111-aaaa-4ea8", label: "someone@example.com",
                             displayName: "Claude account (max)",
                             organizationName: "someone@example.com's Organization"),
                models: []),
            PacerMetrics.AccountToday(
                account: row(id: "2222-3333-bbbb-8c95", label: "other@example.com",
                             displayName: "Claude account (max)",
                             organizationName: "other@example.com's Organization"),
                models: []),
        ])
        #expect(!text.contains("@"))
        #expect(text.contains("name=\"Account 4ea8\""))
        #expect(text.contains("name=\"Account 8c95\""))
    }

    /// A real org name — one that is not just an address — is worth keeping.
    @Test func infoSeriesKeepsARealOrgName() {
        let text = metrics(accounts: [
            PacerMetrics.AccountToday(
                account: row(id: "a", label: "x", displayName: "Claude account (max)",
                             organizationName: "Globex"),
                models: []),
            PacerMetrics.AccountToday(
                account: row(id: "b", label: "y", displayName: "Claude account (max)"),
                models: []),
        ])
        #expect(text.contains("name=\"Globex\""))
        #expect(text.contains("name=\"Account b\""))
    }

    /// The rename is what makes `pacer_account_info` worth joining on: without
    /// one every account reports `Account <last 4>`, because nothing Pacer
    /// observes is safe to publish.
    @Test func aRenameReachesTheMetricLabel() {
        let text = metrics(accounts: [
            PacerMetrics.AccountToday(
                account: row(id: "0000-4ea8", label: "Personal", displayName: "Personal",
                             organizationName: "someone@example.com's Organization"),
                models: []),
            PacerMetrics.AccountToday(
                account: row(id: "1111-8c95", label: "someone@example.com",
                             displayName: "Claude account (max)"),
                models: []),
        ])
        #expect(text.contains("name=\"Personal\""))
        #expect(text.contains("name=\"Account 8c95\""))
        #expect(!text.contains("@"))
    }

    private func metrics(accounts: [PacerMetrics.AccountToday]) -> String {
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
        return PacerMetrics(snapshot: snapshot, todayAccounts: accounts,
                            version: "1.0", build: "1").prometheusText()
    }
}
