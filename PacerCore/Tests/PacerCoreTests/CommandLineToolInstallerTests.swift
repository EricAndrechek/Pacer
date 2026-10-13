import Foundation
import Testing
@testable import PacerCore

/// #257: `pacer` on the PATH for a DMG install. Every path is a temporary
/// stand-in, and the "privileged" scripts run as the test user against them,
/// so nothing here asks for a password or touches /usr/local/bin.
@Suite("Command line on the PATH")
struct CommandLineToolInstallerTests {

    private struct Fixture {
        let root: URL
        init() throws {
            // A quote and a space in the path, so the scripts' quoting is
            // exercised, as "Application Support" always will be.
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("cli path's \(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// A stand-in `pacer` inside an app at `apps/<name>/Pacer.app`.
        func app(_ name: String) throws -> URL {
            let cli = root.appendingPathComponent("apps/\(name)/Pacer.app/" + ClaudeSkillInstaller.cliPathInApp)
            try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "#!/bin/sh\necho \(name)\n".write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
            return cli
        }

        func installer(cli: URL?) -> CommandLineToolInstaller {
            CommandLineToolInstaller(
                cli: cli,
                userLink: root.appendingPathComponent("home/Library/Application Support/Pacer/bin/pacer"),
                systemLink: root.appendingPathComponent("usr/local/bin/pacer"),
                homebrewLinks: [root.appendingPathComponent("opt/homebrew/bin/pacer"),
                                root.appendingPathComponent("usr/local/bin/pacer")])
        }

        func sh(_ script: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }

        func link(_ url: URL, to target: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }

    @Test func installLinksThroughTheUserOwnedLinkAndRemoveTakesItBack() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let cli = try f.app("A")
        let installer = f.installer(cli: cli)
        #expect(installer.state() == .notInstalled)

        // What the Install button does: the user's link, then the one
        // privileged step.
        #expect(try installer.refreshUserLink())
        #expect(f.sh(installer.installScript) == 0)
        #expect(installer.state() == .installed)
        #expect(installer.systemLink.resolvingSymlinksInPath().path == cli.resolvingSymlinksInPath().path)

        #expect(f.sh(installer.uninstallScript) == 0)
        installer.removeUserLink()
        #expect(installer.state() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: installer.userLink.path))
    }

    @Test func aMovedAppIsFollowedWithoutTheRootOwnedLinkChanging() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = f.installer(cli: try f.app("A"))
        try first.refreshUserLink()
        #expect(f.sh(first.installScript) == 0)

        let moved = f.installer(cli: try f.app("B"))
        #expect(try moved.refreshIfInstalled())
        #expect(moved.state() == .installed)
        #expect(moved.systemLink.resolvingSymlinksInPath().path.contains("/apps/B/"))
        #expect(try moved.refreshIfInstalled() == false, "nothing to do the second time")
    }

    @Test func homebrewsLinkIsDeferredTo() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let cli = try f.app("A")
        let brewed = try f.app("Caskroom")
        try f.link(f.root.appendingPathComponent("opt/homebrew/bin/pacer"), to: brewed)
        #expect(f.installer(cli: cli).state()
                == .homebrew(path: f.root.appendingPathComponent("opt/homebrew/bin/pacer").path))
    }

    @Test func intelHomebrewsLinkInUsrLocalIsHomebrewNotForeign() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let installer = f.installer(cli: try f.app("A"))
        try f.link(installer.systemLink, to: try f.app("Caskroom"))
        #expect(installer.state() == .homebrew(path: installer.systemLink.path))
    }

    @Test func aForeignPacerIsNeverReplacedOrRemoved() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let installer = f.installer(cli: try f.app("A"))
        try FileManager.default.createDirectory(at: installer.systemLink.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "#!/bin/sh\necho someone else\n".write(to: installer.systemLink, atomically: true, encoding: .utf8)
        #expect(installer.state() == .foreign(path: installer.systemLink.path))

        try installer.refreshUserLink()
        #expect(f.sh(installer.installScript) != 0, "ln -s refuses to replace it")
        #expect(f.sh(installer.uninstallScript) != 0, "not ours, so not removed")
        #expect(try String(contentsOf: installer.systemLink, encoding: .utf8) == "#!/bin/sh\necho someone else\n")
    }

    @Test func noCommandLineInThisBuild() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let installer = f.installer(cli: nil)
        #expect(installer.state() == .unavailable)
        #expect(try installer.refreshUserLink() == false)
    }

    @Test func quotingSurvivesQuotesAndSpaces() {
        #expect(CommandLineToolInstaller.quoted("/a b/it's") == #"'/a b/it'\''s'"#)
    }
    @Test func aWritableBinNeedsNoPassword() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let installer = f.installer(cli: try f.app("A"))
        // The fixture's usr/local does not exist yet, but its parent is ours.
        #expect(installer.needsPrivileges == false)
        try installer.refreshUserLink()
        try installer.installWithoutPrivileges()
        #expect(installer.state() == .installed)
        try installer.uninstallWithoutPrivileges()
        #expect(installer.state() == .notInstalled)
    }

    @Test func aRootOwnedBinNeedsAPassword() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let installer = f.installer(cli: try f.app("A"))
        let bin = installer.systemLink.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path) }
        #expect(installer.needsPrivileges)
        #expect(throws: (any Error).self) { try installer.installWithoutPrivileges() }
    }

    @Test func removingWithoutAPasswordLeavesAForeignPacer() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let installer = f.installer(cli: try f.app("A"))
        try FileManager.default.createDirectory(at: installer.systemLink.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "theirs\n".write(to: installer.systemLink, atomically: true, encoding: .utf8)
        try installer.uninstallWithoutPrivileges()
        #expect(FileManager.default.fileExists(atPath: installer.systemLink.path))
    }
}
