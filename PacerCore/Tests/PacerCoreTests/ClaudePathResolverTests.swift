import Foundation
import Testing
@testable import PacerCore

@Suite("ClaudePathResolver")
struct ClaudePathResolverTests {

    // MARK: - Test fixtures

    private func makeFixture(file: String = #file, function: String = #function) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeRoot(at base: URL, name: String, withProjectsDir: Bool = true) throws -> URL {
        let root = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if withProjectsDir {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("projects"),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    // MARK: - Tests

    @Test func resolvesXDGAndLegacyTogether() throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        // XDG_CONFIG_HOME points at a directory that CONTAINS a
        // `claude/projects/` subtree (per XDG spec — config dir per
        // app under it). The resolver appends `/claude` itself.
        let xdgConfigHome = base.appendingPathComponent("xdg-config-home")
        try FileManager.default.createDirectory(at: xdgConfigHome, withIntermediateDirectories: true)
        let xdgClaude = try makeRoot(
            at: xdgConfigHome,
            name: "claude"
        )

        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let legacy = try makeRoot(at: home, name: ".claude")

        let resolver = ClaudePathResolver(
            environment: ["XDG_CONFIG_HOME": xdgConfigHome.path],
            homeDirectory: home
        )
        let resolved = try resolver.resolve()

        let roots = resolved.map { $0.root.standardizedFileURL }
        #expect(roots.contains(xdgClaude.standardizedFileURL))
        #expect(roots.contains(legacy.standardizedFileURL))
        #expect(resolved.count == 2)
    }

    @Test func skipsRootWithoutProjectsSubdir() throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = try makeRoot(at: base, name: "home", withProjectsDir: false)

        let resolver = ClaudePathResolver(environment: [:], homeDirectory: home)
        let resolved = try resolver.resolve()
        #expect(resolved.isEmpty)
    }

    @Test func configDirOverrideUsesOnlyProvidedPaths() throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let override = try makeRoot(at: base, name: "override")
        // Even though ~/.claude exists, override takes exclusive precedence.
        let home = base.appendingPathComponent("home")
        _ = try makeRoot(at: home, name: ".claude")

        let resolver = ClaudePathResolver(
            environment: ["CLAUDE_CONFIG_DIR": override.path],
            homeDirectory: home
        )
        let resolved = try resolver.resolve()
        #expect(resolved.count == 1)
        #expect(resolved.first?.root.standardizedFileURL == override.standardizedFileURL)
    }

    @Test func configDirOverrideThrowsWhenAllPathsInvalid() throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let bogus = base.appendingPathComponent("does-not-exist").path

        let resolver = ClaudePathResolver(
            environment: ["CLAUDE_CONFIG_DIR": bogus],
            homeDirectory: base
        )

        #expect(throws: ClaudePathResolver.ResolutionError.self) {
            _ = try resolver.resolve()
        }
    }

    @Test func configDirOverrideAcceptsCommaSeparatedList() throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try makeRoot(at: base, name: "first")
        let second = try makeRoot(at: base, name: "second")
        let resolver = ClaudePathResolver(
            environment: ["CLAUDE_CONFIG_DIR": "\(first.path), \(second.path)"],
            homeDirectory: base
        )
        let resolved = try resolver.resolve()
        #expect(resolved.count == 2)
    }
}
