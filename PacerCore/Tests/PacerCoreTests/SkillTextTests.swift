import Foundation
import Testing
@testable import PacerCore

/// The shipped skill's own text, checked as text: what every session reads.
///
/// Agents read the old skill as a budget. Told "where you stand: `pacer
/// report`" and "keep waves small enough to finish in a few minutes", they kept
/// fan-outs lean and picked weaker models whenever one login's window looked
/// high, with other logins sitting idle. The rule now is that Pacer only stops
/// work; these tests keep the always-loaded text from drifting back into
/// planning advice. `planning.md` (informed mode only) and `reference.md` are
/// where numbers and planning live, and are not held to this.
@Suite("pacer skill text")
struct SkillTextTests {

    /// `Skills/pacer` in this checkout.
    static let skillDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PacerCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // PacerCore
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Skills/pacer", isDirectory: true)

    static func text(_ name: String) throws -> String {
        try String(contentsOf: skillDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// The import loads into every session, so it stays small.
    @Test func theImportIsShort() throws {
        let pacing = try Self.text(ClaudeSkillInstaller.importFileName)
        let lines = pacing.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count <= 30, "pacing.md has \(lines.count) lines")
    }

    /// No percentage in what an agent reads before deciding anything: a
    /// number there is a number to plan with.
    @Test func theImportAndTheSkillCarryNoPercentages() throws {
        for name in ["pacing.md", "SKILL.md"] {
            let text = try Self.text(name)
            let match = text.range(of: #"\d+(\.\d+)?\s?%"#, options: .regularExpression)
            #expect(match == nil, "\(name) contains \(match.map { String(text[$0]) } ?? "")")
        }
    }

    /// The rule is said where every session reads it, and in the skill.
    @Test func bothSayUsageNeverPicksModelWidthOrScope() throws {
        for name in ["pacing.md", "SKILL.md"] {
            let text = try Self.text(name)
            #expect(text.contains("never picks the model"), "\(name)")
            #expect(text.contains("fan-out width"), "\(name)")
        }
    }

    /// Phrases that turned the gate into a planning input. Word-bounded, so
    /// "cleanly" is not "lean".
    @Test func noBudgetPlanningPhrases() throws {
        let banned = [
            #"\blean\b"#, #"small enough"#, #"starting headroom"#, #"what a wave will cost"#,
            #"share of it"#, #"ten more"#, #"stop-and-notify"#, #"Where you stand"#,
            #"same percentage"#,
        ]
        for name in ["pacing.md", "SKILL.md"] {
            let text = try Self.text(name)
            for phrase in banned {
                let match = text.range(of: phrase, options: [.regularExpression, .caseInsensitive])
                #expect(match == nil, "\(name) says /\(phrase)/")
            }
        }
    }

    /// The import points agents at `report` only for the user's questions.
    @Test func theImportDoesNotSendAgentsToReportFirst() throws {
        let pacing = try Self.text("pacing.md")
        #expect(pacing.contains("only when the user asks"))
    }

    /// Every file the skill links to ships beside it.
    @Test func everyLinkedFileShips() throws {
        let skill = try Self.text("SKILL.md")
        let pattern = try NSRegularExpression(pattern: #"\]\(([a-z-]+\.md)\)"#)
        let names = pattern.matches(in: skill, range: NSRange(skill.startIndex..., in: skill)).compactMap {
            Range($0.range(at: 1), in: skill).map { String(skill[$0]) }
        }
        #expect(Set(names) == ["planning.md", "reference.md"], "\(names)")
        for name in names {
            #expect(FileManager.default.fileExists(atPath: Self.skillDirectory.appendingPathComponent(name).path),
                    "\(name) is linked but not shipped")
        }
    }

    /// `pace-guard.sh` pauses at the safe limit unless `PACE_THRESHOLD` is
    /// set; the skill once said 85.
    @Test func paceGuardsDefaultIsDescribedAsTheScriptHasIt() throws {
        let skill = try Self.text("SKILL.md")
        let guardScript = try Self.text("pace-guard.sh")
        #expect(guardScript.contains("default: pace's safe limit"))
        #expect(!skill.contains("(default 85)"))
        #expect(skill.contains("`PACE_THRESHOLD=N` pauses at N% instead"))
    }

    /// The informed guidance says when it applies, so an agent that finds it
    /// without informed pacing on does not take it as license.
    @Test func planningSaysItIsForInformedModeOnly() throws {
        let planning = try Self.text("planning.md")
        #expect(planning.contains("Read this only when informed pacing is on"))
    }
}
