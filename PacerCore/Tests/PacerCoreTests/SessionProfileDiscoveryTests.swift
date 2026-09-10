import Foundation
import Testing
@testable import PacerCore

private func makeHome() throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func makeProfile(_ home: URL, _ name: String, withProjects: Bool) throws -> URL {
    let dir = home.appendingPathComponent(".claude-swap-backup/sessions/\(name)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if withProjects {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }
    return dir.standardizedFileURL
}

@Suite("Session profile discovery")
struct SessionProfileDiscoveryTests {

    @Test("profiles with a projects directory are found")
    func findsUsableProfiles() throws {
        let home = try makeHome()
        let a = try makeProfile(home, "1-work", withProjects: true)
        let b = try makeProfile(home, "2-personal", withProjects: true)
        let found = ExternalAccountDirectory.discoverProfileRoots(homeDirectory: home)
        #expect(found == [a, b])
    }

    @Test("a profile that has never been used is not a root")
    func skipsProfilesWithoutProjects() throws {
        let home = try makeHome()
        _ = try makeProfile(home, "1-work", withProjects: false)
        let used = try makeProfile(home, "2-personal", withProjects: true)
        #expect(ExternalAccountDirectory.discoverProfileRoots(homeDirectory: home) == [used])
    }

    @Test("no switcher installed finds nothing, quietly")
    func noSwitcherIsEmpty() throws {
        let home = try makeHome()
        #expect(ExternalAccountDirectory.discoverProfileRoots(homeDirectory: home).isEmpty)
    }

    @Test("a discovered profile validates as a scannable root")
    func discoveredProfileResolvesAsARoot() throws {
        let home = try makeHome()
        let profile = try makeProfile(home, "2-personal", withProjects: true)
        let resolver = ClaudePathResolver(environment: [:], homeDirectory: home)
        let roots = resolver.resolveAdditional([profile])
        #expect(roots.count == 1)
        #expect(roots.first?.root == profile)
        #expect(roots.first?.projectsDirectory == profile.appendingPathComponent("projects"))
    }

    @Test("a bogus path is dropped rather than breaking the scan")
    func invalidRootsAreDropped() throws {
        let home = try makeHome()
        let resolver = ClaudePathResolver(environment: [:], homeDirectory: home)
        #expect(resolver.resolveAdditional([
            home.appendingPathComponent("does-not-exist")
        ]).isEmpty)
    }

    @Test("the same profile listed twice resolves once")
    func duplicatesCollapse() throws {
        let home = try makeHome()
        let profile = try makeProfile(home, "1-work", withProjects: true)
        let resolver = ClaudePathResolver(environment: [:], homeDirectory: home)
        #expect(resolver.resolveAdditional([profile, profile]).count == 1)
    }

    @Test("a profile's own config names the account that root belongs to")
    func profileConfigIdentifiesItsAccount() throws {
        let home = try makeHome()
        let profile = try makeProfile(home, "2-personal", withProjects: true)
        try """
        {"oauthAccount":{"accountUuid":"acct-2","organizationUuid":"org-personal",
                         "emailAddress":"me@example.com",
                         "organizationName":"Personal Org"}}
        """.write(to: profile.appendingPathComponent(".claude.json"),
                  atomically: true, encoding: .utf8)

        let observer = ActiveAccountObserver()
        let config = observer.currentConfig(forRoot: profile, homeDirectory: home)
        #expect(config != nil)
        let observation = observer.read(configAt: config!.url, rootPath: profile.path)
        #expect(observation?.accountKey == "org-personal")
        #expect(observation?.emailAddress == "me@example.com")
        #expect(observation?.rootPath == profile.path)
    }
}
