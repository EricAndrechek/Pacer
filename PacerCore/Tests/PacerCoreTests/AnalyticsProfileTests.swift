import Foundation
import Testing
@testable import PacerCore

@Suite("PostHog analytics: the install profile on every event")
struct AnalyticsProfileTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("profile.json")
    }

    private let live: Analytics.Properties = [
        "version": .string("1.2.3"), "macos": .string("26.1"), "toggles.usage_data": .bool(true),
        "env.model": .string("Mac99,1"), "menu_bar.shown": .bool(true),
    ]

    /// What a check-in's person dictionary holds: profile keys, plus things
    /// that must never ride on other events.
    private let person: Analytics.Properties = [
        "accounts.count": .int(2), "accounts.plans": .string("max_20x"),
        "install.age_days": .int(41), "install.first_seen": .string("2026-09-25"),
        "clients.cli_count": .int(1), "widgets.count": .int(3), "widgets.installed": .string("a:small"),
        "settings.cost_mode": .string("auto"), "lifecycle.login_item": .bool(true),
        "counter.tab.history": .int(9), "refreshes.today_cost": .int(4), "cli.runs": .int(30),
        "forecast.accuracy": .double(0.8), "usage.five_hour_band": .string("50-75"),
    ]

    @Test("a tab event carries the saved profile; tallies and counters do not")
    func tabCarriesProfile() {
        let profile = AnalyticsProfile(fileURL: nil)
        profile.save(person)
        let event = profile.stamped(.tabViewed(tab: "history", dwellSeconds: 4), live: live)
        #expect(event.set["accounts.count"] == .int(2))
        #expect(event.set["install.first_seen"] == .string("2026-09-25"))
        #expect(event.set["version"] == .string("1.2.3"))
        #expect(event.set["env.model"] == .string("Mac99,1"))
        for key in ["counter.tab.history", "refreshes.today_cost", "cli.runs", "forecast.accuracy",
                    "usage.five_hour_band"] {
            #expect(event.set[key] == nil)
        }
        #expect(event.properties["tab"] != nil)
    }

    @Test("the saved profile survives a relaunch")
    func survivesRelaunch() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        AnalyticsProfile(fileURL: url).save(person)
        let fresh = AnalyticsProfile(fileURL: url)
        #expect(fresh.saved()["accounts.count"] == .int(2))
        #expect(fresh.saved()["lifecycle.login_item"] == .bool(true))
        #expect(fresh.saved()["install.age_days"] == .int(41))
        #expect(fresh.saved()["counter.tab.history"] == nil)
    }

    @Test("a first launch with nothing saved still sends the live part")
    func firstLaunch() {
        let profile = AnalyticsProfile(fileURL: tempFile())
        let event = profile.stamped(.tabViewed(tab: "today", dwellSeconds: 1), live: live)
        #expect(event.set["version"] == .string("1.2.3"))
        #expect(event.set["accounts.count"] == nil)
    }

    @Test("live values beat saved ones, and the event's own set beats both")
    func precedence() {
        let profile = AnalyticsProfile(fileURL: nil)
        profile.save(["accounts.count": .int(1)])
        var e = AnalyticsEvent(.tabViewed, set: ["accounts.count": .int(5), "version": .string("own")])
        e = profile.stamped(e, live: live)
        #expect(e.set["accounts.count"] == .int(5))
        #expect(e.set["version"] == .string("own"))
        #expect(e.set["macos"] == .string("26.1"))
    }

    @Test("live keys outside the allow-list are dropped")
    func liveFiltered() {
        let e = AnalyticsProfile(fileURL: nil).stamped(
            AnalyticsEvent(.tabViewed), live: ["version": .string("1"), "counter.x": .int(1)])
        #expect(e.set["counter.x"] == nil)
    }

    @Test("the profile keys are a subset of what the check-in and person properties send")
    func subsetOfCheckIn() {
        // The check-in's person dictionary is personProperties() plus these
        // attribute keys (DailyCheckIn.sendAnalytics); anything else here
        // would be a new kind of data leaving.
        let checkInAttributes: Set<String> = [
            "accounts.count", "accounts.plans", "install.first_seen", "install.age_days",
            "clients.cli_count", "clients.desktop_count", "clients.profile_count",
            "widgets.count", "widgets.installed",
            "settings.menu_bar_chips", "settings.menu_bar_scoped_chips", "settings.menu_bar_icon_style",
            "settings.api_server_on", "settings.notifications_on", "settings.cost_mode",
            "settings.desktop_credentials_on", "settings.switcher_on", "settings.skill_installed",
            "lifecycle.login_item", "env.model", "env.model_name",
        ]
        let personProperties: Set<String> = [
            "version", "build.config", "macos", "menu_bar.shown", "menu_bar.chips", "menu_bar.icon_style",
            "menu_bar.icon_driver", "toggles.crash_reports", "toggles.performance", "toggles.usage_data",
            "env.model", "env.model_name",
        ]
        #expect(AnalyticsProfile.keys.isSubset(of: checkInAttributes.union(personProperties)))
        for banned in ["counter.", "refreshes.", "cli.", "usage.", "forecast.", "accuracy"] {
            #expect(!AnalyticsProfile.keys.contains { $0.hasPrefix(banned) })
        }
    }

    @Test("the outgoing item carries the profile as $set, cleaned, and stays small")
    func payloadSize() throws {
        let profile = AnalyticsProfile(fileURL: nil)
        profile.save(person)
        let context = AnalyticsPayload.Context(
            distinctId: "ID", appVersion: "1", appBuild: "1", buildConfig: "release", macOS: "26.1")
        let bare = AnalyticsPayload.item(.tabViewed(tab: "history", dwellSeconds: 4), context: context)
        let full = AnalyticsPayload.item(
            profile.stamped(.tabViewed(tab: "history", dwellSeconds: 4), live: live), context: context)
        let set = try #require((full["properties"] as? [String: Any])?["$set"] as? [String: Any])
        #expect(set["accounts.count"] as? Int == 2)
        let added = try JSONSerialization.data(withJSONObject: full).count
            - JSONSerialization.data(withJSONObject: bare).count
        #expect(added < 1_500)
    }

    @Test("with usage data off the sink sends nothing, and the profile is not stamped")
    func toggleOff() {
        // The app's sink returns before stamping when the toggle is off; this
        // models it with a sink that mirrors that order.
        final class Recorder: @unchecked Sendable { var events: [AnalyticsEvent] = [] }
        struct Sink: Analytics.Sink {
            let on: Bool; let recorder: Recorder; let profile: AnalyticsProfile
            func capture(_ event: AnalyticsEvent) {
                guard on else { return }
                recorder.events.append(profile.stamped(event, live: [:]))
            }
        }
        let recorder = Recorder()
        let profile = AnalyticsProfile(fileURL: nil)
        profile.save(person)
        Sink(on: false, recorder: recorder, profile: profile).capture(.tabViewed(tab: "x", dwellSeconds: 1))
        #expect(recorder.events.isEmpty)
        Sink(on: true, recorder: recorder, profile: profile).capture(.tabViewed(tab: "x", dwellSeconds: 1))
        #expect(recorder.events.count == 1)
    }
}
