import Foundation
import Testing
@testable import PacerCore

@Suite("Version label: release and dev builds")
struct AppVersionLabelTests {

    private func dev(describe: String? = nil, sha: String? = nil, dirty: String? = nil,
                     debug: Bool = true) -> AppVersionLabel {
        var info: [String: Any] = ["CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "1780503333"]
        info[AppVersionLabel.describeKey] = describe ?? ""
        info[AppVersionLabel.shaKey] = sha ?? ""
        info[AppVersionLabel.dirtyKey] = dirty ?? ""
        return AppVersionLabel(info: info, isDebugBuild: debug)
    }

    @Test("a release build shows its marketing version")
    func release() {
        let label = AppVersionLabel(info: ["CFBundleShortVersionString": "0.9.4",
                                           "CFBundleVersion": "1780503333",
                                           AppVersionLabel.describeKey: "", AppVersionLabel.shaKey: "",
                                           AppVersionLabel.dirtyKey: ""],
                                    isDebugBuild: false)
        #expect(label.kind == .release("0.9.4"))
        #expect(label.isRelease)
        #expect(label.text == "0.9.4")
        #expect(label.title == "Pacer 0.9.4")
        #expect(label.aboutLine == "Version 0.9.4")
        #expect(label.buildLine == "Build 1780503333")
        #expect(label.reportVersion == "0.9.4")
        #expect(label.reportDescribe == nil)
    }

    @Test("a dev build past a tag: the tag, how far past it, and the commit")
    func devPastTag() {
        let label = dev(describe: "v0.9.4-14-g9eb8c89", sha: "9eb8c89d1180fe83c60eeb25673caab894ec80d4", dirty: "0")
        #expect(!label.isRelease)
        #expect(label.text == "0.9.4+14 · dev (9eb8c89)")
        #expect(label.title == "Pacer 0.9.4+14 · dev (9eb8c89)")
        #expect(label.aboutLine == "Version 0.9.4+14 · dev (9eb8c89)")
        #expect(label.reportVersion == "0.9.4")
        #expect(label.reportDescribe == "v0.9.4-14-g9eb8c89")
    }

    @Test("the forms a narrow line falls back through, never cut mid-commit")
    func fittedTitles() {
        #expect(dev(describe: "v0.9.4-14-g9eb8c89", sha: "9eb8c89d", dirty: "0").fittedTitles
                == ["Pacer 0.9.4+14 · dev (9eb8c89)", "0.9.4+14 · dev (9eb8c89)", "0.9.4+14 · dev", "dev"])
        #expect(dev(describe: "v0.9.4-0-gc4bc89de", dirty: "0").fittedTitles
                == ["Pacer 0.9.4 · dev (c4bc89d)", "0.9.4 · dev (c4bc89d)", "0.9.4 · dev", "dev"])
        #expect(dev().fittedTitles == ["Pacer dev", "dev"])
        #expect(AppVersionLabel(kind: .release("0.9.4")).fittedTitles == ["Pacer 0.9.4", "0.9.4"])
    }

    @Test("uncommitted changes put a * after the commit")
    func dirty() {
        let label = dev(describe: "v0.9.4-14-g9eb8c89", sha: "9eb8c89d", dirty: "1")
        #expect(label.text == "0.9.4+14 · dev (9eb8c89*)")
        #expect(label.reportDescribe == "v0.9.4-14-g9eb8c89-dirty")
    }

    @Test("on the tag itself there is no +0")
    func onTag() {
        #expect(dev(describe: "v0.9.4-0-gc4bc89de", sha: "c4bc89de11", dirty: "0").text == "0.9.4 · dev (c4bc89d)")
    }

    @Test("git's longer abbreviation is shown at seven characters")
    func longAbbreviation() {
        #expect(dev(describe: "v0.9.4-1-gc4bc89de", dirty: "0").text == "0.9.4+1 · dev (c4bc89d)")
    }

    @Test("a dev build is a dev build in either configuration")
    func releaseConfiguration() {
        #expect(dev(describe: "v0.9.4-3-g9eb8c89", sha: "9eb8c89aa", debug: false).text == "0.9.4+3 · dev (9eb8c89)")
    }

    @Test("a tag with dashes of its own still parses")
    func dashedTag() {
        #expect(dev(describe: "v1.0.0-beta.2-5-gabcdef0", sha: "abcdef0123").text == "1.0.0-beta.2+5 · dev (abcdef0)")
    }

    @Test("no tag in reach (a shallow clone): the commit alone")
    func noTag() {
        let label = dev(sha: "9eb8c89d1180fe83", dirty: "1")
        #expect(label.text == "dev (9eb8c89*)")
        // X.Y.Z, which the feedback endpoint requires.
        #expect(label.reportVersion == "0.0.0")
        #expect(label.reportDescribe == "9eb8c89-dirty")
    }

    @Test("a Debug build with no git state is plain dev, never project.yml's placeholder version")
    func devWithoutGit() {
        let label = dev()
        #expect(label.text == "dev")
        #expect(label.title == "Pacer dev")
        #expect(label.reportDescribe == nil)
    }

    @Test("unexpanded or malformed values are no value")
    func malformed() {
        let label = AppVersionLabel(info: ["CFBundleShortVersionString": "0.9.4",
                                           AppVersionLabel.describeKey: "$(PACER_GIT_DESCRIBE)",
                                           AppVersionLabel.shaKey: "not-a-sha"],
                                    isDebugBuild: false)
        #expect(label.kind == .release("0.9.4"))
        #expect(AppVersionLabel.parseDescribe("v0.9.4") == nil)
        #expect(AppVersionLabel.parseDescribe("v0.9.4-x-g9eb8c89") == nil)
        #expect(AppVersionLabel.shortCommit(" abcdef1234\n") == "abcdef1")
    }

    @Test("a release with no version string still says something")
    func missingVersion() {
        #expect(AppVersionLabel(info: [:], isDebugBuild: false).text == "0")
    }
}

@Suite("Update status: Sparkle's callbacks to what the surfaces show")
struct UpdateStateTests {

    private func run(_ events: [UpdateState.Event], from start: UpdateState = .upToDate) -> UpdateState {
        events.reduce(start) { $0.applying($1) }
    }

    @Test("a check that finds nothing ends up to date")
    func noUpdate() {
        #expect(UpdateState.upToDate.applying(.checkStarted) == .checking)
        #expect(run([.checkStarted, .noUpdate, .cycleFinished(failed: false)]) == .upToDate)
        // "You're up to date" also arrives through the error channel.
        #expect(run([.checkStarted, .aborted(noUpdate: true), .cycleFinished(failed: false)]) == .upToDate)
    }

    @Test("an automatic update: checking, downloading, then handed to the install hold")
    func automaticUpdate() {
        #expect(run([.checkStarted, .downloadStarted(version: "0.9.5")]) == .downloading(version: "0.9.5"))
        let afterHandOff = run([.checkStarted, .downloadStarted(version: "0.9.5"), .prepared])
        #expect(afterHandOff == .upToDate)
        // While the hold has it, the hold is what shows.
        #expect(UpdateState.resolve(phase: afterHandOff, heldVersion: "0.9.5") == .readyToInstall(version: "0.9.5"))
        // Released (its session ended): nothing to act on.
        #expect(UpdateState.resolve(phase: afterHandOff, heldVersion: nil) == .upToDate)
    }

    @Test("a held update wins over whatever the last check said")
    func holdWins() {
        for phase in [UpdateState.upToDate, .checking, .downloading(version: "0.9.5"), .failed] {
            #expect(UpdateState.resolve(phase: phase, heldVersion: "0.9.6") == .readyToInstall(version: "0.9.6"))
            #expect(UpdateState.resolve(phase: phase, heldVersion: nil) == phase)
        }
        // The phase never claims ready on its own.
        #expect(UpdateState.resolve(phase: .readyToInstall(version: "0.9.5"), heldVersion: nil) == .upToDate)
    }

    @Test("an install under way shows as installing, so the action greys out")
    func installing() {
        let state = UpdateState.resolve(phase: .upToDate, heldVersion: "0.9.5", installing: true)
        #expect(state == .installing(version: "0.9.5"))
        #expect(state.isInstalling)
        #expect(state.readyVersion == "0.9.5")
        #expect(!UpdateState.readyToInstall(version: "0.9.5").isInstalling)
        // The hold gone: nothing to install, whatever was under way.
        #expect(UpdateState.resolve(phase: .upToDate, heldVersion: nil, installing: true) == .upToDate)
        // The menu keeps its item (shown disabled).
        #expect(UpdateCopy.menuInstallTitle(for: state) == "Update to 0.9.5 — Restart")
        #expect(UpdateState(override: "installing:0.9.5") == state)
        #expect(state.token == "installing-0.9.5")
    }

    @Test("a pending update shows its action; a hold wins over it; its download shows as one; a click restarts once downloaded")
    func available() {
        for phase in [UpdateState.upToDate, .checking, .failed] {
            let state = UpdateState.resolve(phase: phase, heldVersion: nil, availableVersion: "0.9.6")
            #expect(state == .available(version: "0.9.6"))
            #expect(state.readyVersion == "0.9.6")
            #expect(state.isAvailable)
            #expect(!state.isInstalling)
        }
        #expect(UpdateState.resolve(phase: .upToDate, heldVersion: "0.9.7", availableVersion: "0.9.6")
                == .readyToInstall(version: "0.9.7"))
        // An arm's download shows as a download, the policy's or a click's.
        #expect(UpdateState.resolve(phase: .downloading(version: "0.9.7"), heldVersion: nil,
                                    availableVersion: "0.9.7") == .downloading(version: "0.9.7"))
        #expect(UpdateState.resolve(phase: .downloading(version: "0.9.7"), heldVersion: nil,
                                    availableVersion: "0.9.7", requested: true) == .downloading(version: "0.9.7"))
        // A click: downloading from its check on, restarting once downloaded.
        #expect(UpdateState.resolve(phase: .checking, heldVersion: nil, availableVersion: "0.9.7", requested: true)
                == .downloading(version: "0.9.7"))
        let clicked = UpdateState.resolve(phase: .upToDate, heldVersion: nil, availableVersion: "0.9.7",
                                          requested: true)
        #expect(clicked == .installing(version: "0.9.7"))
        #expect(!clicked.isAvailable)
        // The policy's arm reading the feed: still just available.
        #expect(UpdateState.resolve(phase: .checking, heldVersion: nil, availableVersion: "0.9.7")
                == .available(version: "0.9.7"))
        // The phase never claims available on its own.
        #expect(UpdateState.resolve(phase: .available(version: "0.9.6"), heldVersion: nil) == .upToDate)
        #expect(!UpdateState.readyToInstall(version: "0.9.6").isAvailable)
        #expect(UpdateCopy.menuInstallTitle(for: .available(version: "0.9.6")) == "Update to 0.9.6 — Restart")
        #expect(UpdateState(override: "available:0.9.6") == .available(version: "0.9.6"))
        #expect(UpdateState(override: "available") == nil)
        #expect(UpdateState.available(version: "0.9.6").token == "available-0.9.6")
    }

    @Test("a failure stands until the next check")
    func failure() {
        let failedDownload = run([.checkStarted, .downloadStarted(version: "0.9.5"), .downloadFailed])
        #expect(failedDownload == .failed)
        // The cycle's end does not always repeat the error; the failure stands.
        #expect(failedDownload.applying(.cycleFinished(failed: false)) == .failed)
        #expect(run([.checkStarted, .aborted(noUpdate: false)]) == .failed)
        #expect(run([.checkStarted, .cycleFinished(failed: true)]) == .failed)
        #expect(UpdateState.failed.applying(.checkStarted) == .checking)
    }

    @Test("nothing in progress outlives its cycle")
    func cycleEndBackstop() {
        #expect(UpdateState.checking.applying(.cycleFinished(failed: false)) == .upToDate)
        #expect(UpdateState.downloading(version: "0.9.5").applying(.cycleFinished(failed: false)) == .upToDate)
    }

    @Test("Sparkle's no-update error is recognised, nothing else is")
    func noUpdateError() {
        #expect(UpdateState.isNoUpdate(domain: "SUSparkleErrorDomain", code: 1001))
        #expect(!UpdateState.isNoUpdate(domain: "SUSparkleErrorDomain", code: 2001))
        #expect(!UpdateState.isNoUpdate(domain: NSURLErrorDomain, code: 1001))
    }

    @Test("render overrides parse, and name their files")
    func overrides() {
        #expect(UpdateState(override: "ready:0.9.5") == .readyToInstall(version: "0.9.5"))
        #expect(UpdateState(override: "downloading:0.9.5") == .downloading(version: "0.9.5"))
        #expect(UpdateState(override: "up-to-date") == .upToDate)
        #expect(UpdateState(override: "Checking") == .checking)
        #expect(UpdateState(override: "failed") == .failed)
        #expect(UpdateState(override: "ready") == nil)
        #expect(UpdateState(override: "ready:") == nil)
        #expect(UpdateState(override: "bogus") == nil)
        #expect(UpdateState.readyToInstall(version: "0.9.5").token == "ready-0.9.5")
        #expect(UpdateState.downloading(version: "0.9.5").token == "downloading-0.9.5")
        #expect(UpdateState.upToDate.token == "up-to-date")
    }
}

@Suite("Update and feedback copy")
struct UpdateFeedbackCopyTests {

    @Test("the update strings, per surface")
    func updateStrings() {
        #expect(UpdateCopy.sidebarInstall == "Restart to Update")
        #expect(UpdateCopy.sidebarReady("0.9.5") == "Pacer 0.9.5 is ready")
        #expect(UpdateCopy.sidebarAvailable("0.9.5") == "Pacer 0.9.5 is available")
        #expect(UpdateCopy.menuInstall("0.9.5") == "Update to 0.9.5 — Restart")
        #expect(UpdateCopy.downloading("0.9.5") == "Downloading 0.9.5…")
        #expect(UpdateCopy.checkForUpdates == "Check for Updates…")
    }

    @Test("the status menu offers the install only while an update is available or ready")
    func menuUpdateItem() {
        #expect(UpdateCopy.menuInstallTitle(for: .readyToInstall(version: "0.9.5")) == "Update to 0.9.5 — Restart")
        for state in [UpdateState.upToDate, .checking, .downloading(version: "0.9.5"), .failed] {
            #expect(UpdateCopy.menuInstallTitle(for: state) == nil)
        }
    }

    @Test("the feedback entry points and window")
    func feedbackStrings() {
        #expect(FeedbackCopy.menuItem == "Send Feedback…")
        #expect(FeedbackCopy.button == "Feedback")
        #expect(FeedbackCopy.windowTitle == "Send Feedback")
    }

    @Test("each kind has its label and question, and leads its report")
    func kinds() {
        #expect(FeedbackKind.allCases == [.idea, .problem, .other])
        #expect(FeedbackKind.allCases.map(\.title) == ["Idea", "Problem", "Something else"])
        #expect(FeedbackKind.idea.prompt == "What would make Pacer better? A line is plenty.")
        #expect(FeedbackKind.problem.prompt == "What went wrong, and what did you expect?")
        #expect(FeedbackKind.other.prompt == "What's on your mind?")
        #expect(FeedbackKind.idea.report("Dark mode please") == "[Idea] Dark mode please")
        #expect(FeedbackKind.other.report("Hi") == "[Something else] Hi")
    }
}

@Suite("Feedback and update analytics")
struct FeedbackAnalyticsTests {

    @Test("feedback_sent carries the kind and the route, nothing else")
    func feedbackSent() {
        let event = AnalyticsEvent.feedbackSent(kind: .idea, via: .site)
        #expect(event.name == "feedback_sent")
        #expect(event.properties == ["kind": .string("idea"), "via": .string("site")])
        let github = AnalyticsEvent.feedbackSent(kind: .other, via: .github)
        #expect(github.properties == ["kind": .string("other"), "via": .string("github")])
    }

    @Test("the open event keeps its name and gains the sidebar")
    func opened() {
        let event = AnalyticsEvent.reportProblemOpened(from: .sidebar)
        #expect(event.name == "report_problem_opened")
        #expect(event.properties == ["from": .string("sidebar")])
        #expect(AnalyticsEvent.ReportProblemSource.allCases.map(\.rawValue)
                == ["help_menu", "status_menu", "settings", "sidebar"])
    }

    @Test("the status menu's items: feedback under its old name, and the update")
    func menuItems() {
        #expect(AnalyticsEvent.menubarItemClicked(.reportProblem).properties["item"] == .string("report_problem"))
        let update = AnalyticsEvent.menubarItemClicked(.installUpdate)
        #expect(update.name == "menubar_item_clicked")
        #expect(update.properties["item"] == .string("install_update"))
    }

    @Test("the payload keeps both properties (neither is a forbidden key)")
    func payload() throws {
        let context = AnalyticsPayload.Context(distinctId: "0D3C8A41-1F2B-4C5D-9E8F-0123456789AB",
                                               appVersion: "0.9.4", appBuild: "1", buildConfig: "release",
                                               macOS: "26.1")
        let item = AnalyticsPayload.item(.feedbackSent(kind: .problem, via: .site), context: context, home: "/Users/a")
        let props = try #require(item["properties"] as? [String: Any])
        #expect(props["kind"] as? String == "problem")
        #expect(props["via"] as? String == "site")
    }
}
