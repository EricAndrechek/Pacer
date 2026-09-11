import Foundation
import Testing
@testable import PacerCore

/// Installing into `~/.claude` is writing in someone else's house: the rules
/// are that it happens on a click, that a file the user edited is theirs, and
/// that removal takes back exactly what was put there.
@Suite("Claude Code skill installer")
struct ClaudeSkillInstallerTests {

    private struct Fixture {
        let root: URL
        let installer: ClaudeSkillInstaller

        init(version: String = "1.0 (100)") throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("skill-\(UUID().uuidString)")
            let source = root.appendingPathComponent("bundle/Skills/pacer")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "---\nname: pacer\n---\nbody\n".write(
                to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try "#!/usr/bin/env bash\necho hi\n".write(
                to: source.appendingPathComponent("pace.sh"), atomically: true, encoding: .utf8)
            installer = ClaudeSkillInstaller(
                source: source,
                destination: root.appendingPathComponent("home/.claude/skills/pacer"),
                version: version)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func installedFile(_ name: String) -> URL {
            installer.destination.appendingPathComponent(name)
        }
    }

    @Test func installCopiesEveryFileAndMakesScriptsExecutable() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(f.installer.status().state == .notInstalled)

        try f.installer.install()

        #expect(f.installer.status().state == .upToDate)
        #expect(FileManager.default.fileExists(atPath: f.installedFile("SKILL.md").path))
        // Xcode's resource copy does not reliably carry the executable bit, so
        // the installer sets it — a skill whose script cannot run is a puzzle,
        // not an error message.
        let mode = try FileManager.default.attributesOfItem(
            atPath: f.installedFile("pace.sh").path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o755)
        let docMode = try FileManager.default.attributesOfItem(
            atPath: f.installedFile("SKILL.md").path)[.posixPermissions] as? NSNumber
        #expect(docMode?.int16Value == 0o644)
    }

    @Test func aNewerBundledVersionReadsAsOutdatedAndRefreshes() throws {
        let f = try Fixture(version: "1.0 (100)"); defer { f.cleanup() }
        try f.installer.install()

        let newer = ClaudeSkillInstaller(source: f.installer.source,
                                         destination: f.installer.destination,
                                         version: "1.1 (110)")
        #expect(newer.status().state == .outdated(installed: "1.0 (100)"))
        #expect(newer.status().needsRefresh)
        #expect(try newer.refreshIfInstalled() == true)
        #expect(newer.status().state == .upToDate)
        // Idempotent: a second launch has nothing to do.
        #expect(try newer.refreshIfInstalled() == false)
    }

    /// The reason the manifest stores hashes at all. An auto-refresh that
    /// overwrote a file the user had edited would be a silent data loss on
    /// every app update.
    @Test func anEditedFileIsNeverOverwrittenByARefresh() throws {
        let f = try Fixture(version: "1.0 (100)"); defer { f.cleanup() }
        try f.installer.install()
        try "# my own notes\n".write(to: f.installedFile("SKILL.md"),
                                     atomically: true, encoding: .utf8)

        let newer = ClaudeSkillInstaller(source: f.installer.source,
                                         destination: f.installer.destination,
                                         version: "1.1 (110)")
        #expect(newer.status().state == .modified(installed: "1.0 (100)"))
        #expect(newer.status().needsRefresh == false)
        #expect(try newer.refreshIfInstalled() == false)
        #expect(try String(contentsOf: f.installedFile("SKILL.md"), encoding: .utf8)
            == "# my own notes\n")

        // An explicit install (the card's "Overwrite") still replaces it.
        try newer.install()
        #expect(newer.status().state == .upToDate)
    }

    /// Someone else's skill of the same name must not be silently adopted or
    /// clobbered — Pacer only recognises a directory carrying its manifest.
    @Test func aDirectoryWithNoManifestIsForeign() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.installer.destination,
                                                withIntermediateDirectories: true)
        try "hand rolled\n".write(to: f.installedFile("SKILL.md"),
                                  atomically: true, encoding: .utf8)
        #expect(f.installer.status().state == .foreign)
        #expect(f.installer.status().needsRefresh == false)
        #expect(throws: ClaudeSkillInstaller.Error.notOurs) { try f.installer.uninstall() }
    }

    @Test func uninstallTakesBackOnlyWhatItInstalled() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.installer.install()
        let mine = f.installedFile("my-notes.md")
        try "keep me\n".write(to: mine, atomically: true, encoding: .utf8)

        try f.installer.uninstall()

        #expect(!FileManager.default.fileExists(atPath: f.installedFile("SKILL.md").path))
        #expect(!FileManager.default.fileExists(
            atPath: f.installedFile(ClaudeSkillInstaller.manifestName).path))
        // The user's own file — and therefore the directory — survives.
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    @Test func uninstallRemovesTheDirectoryWhenNothingElseIsLeft() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.installer.install()
        try f.installer.uninstall()
        #expect(!FileManager.default.fileExists(atPath: f.installer.destination.path))
        #expect(f.installer.status().state == .notInstalled)
    }

    @Test func hiddenFilesAreNotPartOfTheSkill() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try "junk".write(to: f.installer.source.appendingPathComponent(".DS_Store"),
                         atomically: true, encoding: .utf8)
        let files = f.installer.sourceFiles()
        #expect(files == ["SKILL.md", "pace.sh"])
    }

    /// The import line is a *pointer*, and that is the whole point: the prose
    /// it names ships inside the app and is replaced on every update, so a
    /// user's CLAUDE.md never needs re-pasting. Pasting the prose itself is how
    /// the instructions this replaced went stale.
    @Test func theImportLinePointsAtTheInstalledFileRatherThanCarryingIt() {
        let line = ClaudeSkillInstaller.claudeMdImportLine
        #expect(line == "@~/.claude/skills/pacer/pacing.md")
        // One line, no prose: anything longer is content that would go stale.
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("@"))
    }

    /// The importable file has to actually ship, or the line a user pastes
    /// points at nothing.
    @Test func theImportedFileIsPartOfTheInstalledSkill() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try "## Pacing\n".write(
            to: f.installer.source.appendingPathComponent(ClaudeSkillInstaller.importFileName),
            atomically: true, encoding: .utf8)

        try f.installer.install()

        #expect(FileManager.default.fileExists(
            atPath: f.installedFile(ClaudeSkillInstaller.importFileName).path))
        // And it is tracked, so a Pacer update re-syncs it like everything else
        // — which is what keeps the pointer honest.
        #expect(f.installer.readManifest()?.files[ClaudeSkillInstaller.importFileName] != nil)
    }

    /// A PacerCore-only build has no app bundle to read the skill out of, and
    /// that is a build shape rather than a user-facing failure.
    @Test func aBundleWithoutTheSkillIsUnavailable() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let empty = ClaudeSkillInstaller(
            source: f.root.appendingPathComponent("nothing-here"),
            destination: f.installer.destination, version: "1.0 (100)")
        #expect(empty.status().state == .unavailable)
        #expect(throws: ClaudeSkillInstaller.Error.noBundledSkill) { try empty.install() }
    }
}
