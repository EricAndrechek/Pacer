import Foundation
import Testing
@testable import PacerCore

/// Where the app reads its update feed and price history from 0.9.4: the
/// site's own static files (site/public/ on main, written by the release
/// workflow through bin/publish-feeds.sh, served at pacer.andrechek.com). A
/// build pointed anywhere else is stranded the day that place stops getting
/// releases, and only an update could move it back, so the location is pinned
/// here and in `bin/ship.sh self-test`.
@Suite("Feed location")
struct FeedLocationTests {

    static let site = "pacer.andrechek.com"
    /// The repository root, from this file (PacerCore/Tests/PacerCoreTests/).
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func thePriceHistoryIsTheSitesStaticFile() {
        let url = CuratedPriceHistory.remoteURL
        #expect(url.scheme == "https")
        #expect(url.host == Self.site)
        #expect(url.path == "/price-history.json")
        #expect(url.query == nil)
    }

    /// project.yml generates Info.plist (XcodeGen), and the checked-in plist is
    /// what a build without a regenerate uses: the two must name one feed.
    @Test func infoPlistAndProjectYmlNameTheSameSiteFeed() throws {
        let plistData = try Data(contentsOf: Self.repo.appendingPathComponent("App/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let fromPlist = try #require(plist["SUFeedURL"] as? String)

        let yml = try String(contentsOf: Self.repo.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = yml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let feedLines = lines.filter { $0.hasPrefix("SUFeedURL:") }
        #expect(feedLines.count == 1)
        let fromYml = try #require(feedLines.first).dropFirst("SUFeedURL:".count)
            .trimmingCharacters(in: .whitespaces)

        #expect(fromPlist == fromYml)
        let url = try #require(URL(string: fromPlist))
        #expect(url.scheme == "https")
        #expect(url.host == Self.site)
        #expect(url.path == "/appcast.xml")
        // The price history is published beside the feed.
        #expect(CuratedPriceHistory.remoteURL.host == url.host)
    }

    /// Every path the app fetches is a file of the site, not a Worker route.
    @Test func bothFilesAreInTheSitesPublicDirectory() throws {
        let publicDir = Self.repo.appendingPathComponent("site/public")
        #expect(FileManager.default.fileExists(atPath: publicDir.appendingPathComponent("appcast.xml").path))
        let prices = try Data(contentsOf: publicDir.appendingPathComponent(
            String(CuratedPriceHistory.remoteURL.path.dropFirst())))
        // The copy the site serves is one this build decodes.
        let decoded = try CuratedPriceHistory.decode(prices)
        #expect(!decoded.records.isEmpty)
    }
}
