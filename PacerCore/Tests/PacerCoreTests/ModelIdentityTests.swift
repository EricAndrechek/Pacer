import Foundation
import SwiftUI
import Testing
import PacerUI

/// Tests for the model-id parser, its display names, and the curated
/// family/version color scheme. The parser must handle the modern order,
/// the legacy `claude-3-5-sonnet` order, provider prefixes, date pins, the
/// `[1m]` variant, and — crucially — its own pretty output, so a color
/// keyed on `"Opus 4.7"` matches one keyed on `claude-opus-4-7`.
struct ModelIdentityTests {

    private func hex(_ model: String) -> String? {
        pacerHexString(from: pacerModelColor(model))
    }

    // MARK: Parsing + display names

    @Test func modernIdParses() {
        let id = PacerModelIdentity("claude-opus-4-7")
        #expect(id.family == .opus)
        #expect(id.major == 4)
        #expect(id.minor == 7)
        #expect(id.datePin == nil)
        #expect(id.displayName == "Opus 4.7")
    }

    @Test func bareFlagshipHasNoMinor() {
        let id = PacerModelIdentity("claude-sonnet-5")
        #expect(id.family == .sonnet)
        #expect(id.major == 5)
        #expect(id.minor == nil)
        #expect(id.displayName == "Sonnet 5")
    }

    @Test func datePinIsCapturedNotTreatedAsVersion() {
        let id = PacerModelIdentity("claude-haiku-4-5-20251001")
        #expect(id.family == .haiku)
        #expect(id.major == 4)
        #expect(id.minor == 5)
        #expect(id.datePin == "20251001")
        #expect(id.displayName == "Haiku 4.5")
    }

    @Test func legacyOrderParses() {
        let sonnet = PacerModelIdentity("claude-3-5-sonnet-20241022")
        #expect(sonnet.family == .sonnet)
        #expect(sonnet.major == 3)
        #expect(sonnet.minor == 5)
        #expect(sonnet.displayName == "Sonnet 3.5")

        let opus = PacerModelIdentity("claude-3-opus-20240229")
        #expect(opus.family == .opus)
        #expect(opus.major == 3)
        #expect(opus.minor == nil)
        #expect(opus.displayName == "Opus 3")
    }

    @Test func providerPrefixesAreStripped() {
        #expect(PacerModelIdentity("anthropic/claude-opus-4-7").displayName == "Opus 4.7")
        #expect(PacerModelIdentity("us.anthropic.claude-sonnet-5").displayName == "Sonnet 5")
        #expect(PacerModelIdentity("vertex_ai/claude-sonnet-4-6@default").displayName == "Sonnet 4.6")
        // A rev suffix must not leak into the version.
        let rev = PacerModelIdentity("claude-sonnet-4-5-20250929-v1:0")
        #expect(rev.major == 4)
        #expect(rev.minor == 5)
    }

    @Test func contextVariantIsFlaggedAndLabeled() {
        let id = PacerModelIdentity("claude-opus-4-8[1m]")
        #expect(id.context1M)
        #expect(id.major == 4)
        #expect(id.minor == 8)
        #expect(id.displayName == "Opus 4.8 1M")
    }

    @Test func fableAndMythosAreDistinctFamilies() {
        #expect(PacerModelIdentity("claude-fable-5").family == .fable)
        #expect(PacerModelIdentity("claude-mythos-5").family == .mythos)
    }

    @Test func unknownFamilyFallsBackToShortName() {
        let id = PacerModelIdentity("gpt-4o")
        #expect(id.family == nil)
        #expect(id.displayName == pacerShortModel("gpt-4o"))
    }

    // MARK: Color scheme

    @Test func colorIsDeterministic() {
        #expect(hex("claude-opus-4-7") == hex("claude-opus-4-7"))
    }

    @Test func colorIsSymmetricAcrossRawAndDisplayForms() {
        // A color keyed on the pretty label must equal one keyed on the id —
        // the trend chart colors by display name, other views by raw id.
        #expect(hex("claude-opus-4-7") == hex("Opus 4.7"))
        #expect(hex("claude-sonnet-5") == hex("Sonnet 5"))
    }

    @Test func providerPrefixDoesNotSplitColor() {
        #expect(hex("anthropic/claude-opus-4-7") == hex("claude-opus-4-7"))
    }

    @Test func familiesGetDistinctColors() {
        let families = ["claude-opus-4-8", "claude-sonnet-5",
                        "claude-haiku-4-5", "claude-fable-5", "claude-mythos-5"]
        let colors = Set(families.compactMap { hex($0) })
        #expect(colors.count == families.count)
    }

    @Test func versionsWithinFamilyAreShadedDistinctly() {
        // The whole point of shade-by-version: adjacent Opus sub-versions
        // must be visibly different colors.
        let opus = ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8"]
        let colors = Set(opus.compactMap { hex($0) })
        #expect(colors.count == opus.count)
    }

    @Test func unknownFamilyColorMatchesGeneratedFallback() {
        #expect(hex("gpt-4o") == pacerHexString(from: pacerGeneratedColor(pacerShortModel("gpt-4o"))))
    }

    // MARK: Robust parsing

    @Test func contiguousDigitsIgnoreProviderRegion() {
        // The `1` in `us-gov-east-1` must NOT become a version — this is
        // Claude 3 Haiku (3.0), not 3.1.
        let id = PacerModelIdentity("bedrock/us-gov-east-1/anthropic.claude-3-haiku-20240307-v1:0")
        #expect(id.family == .haiku)
        #expect(id.major == 3)
        #expect(id.minor == nil)
    }

    @Test func compressedProviderVersionSplits() {
        let a = PacerModelIdentity("github_copilot/claude-opus-41")   // "41" → 4.1
        #expect(a.major == 4 && a.minor == 1)
        let b = PacerModelIdentity("claude-sonnet-45")                // "45" → 4.5
        #expect(b.major == 4 && b.minor == 5)
        // A leading digit < 3 stays a real major (Claude 10, not 1.0).
        let c = PacerModelIdentity("claude-opus-10")
        #expect(c.major == 10)
    }

    @Test func canonicalTreatsBareMajorAsMinorZero() {
        let id = PacerModelIdentity("claude-opus-4")
        #expect(id.canonical?.minor == 0)      // color math sees minor 0
        #expect(id.minor == nil)               // …but display stays "Opus 4"
        #expect(id.displayName == "Opus 4")
    }

    // MARK: Palette

    @Test func uncataloguedVersionStaysDistinctFromCatalogued() {
        // Opus 5 isn't in the bundled catalog yet; it must still get its own
        // color, not collide with Opus 4.8 (the catalogued newest).
        #expect(hex("claude-opus-5") != hex("claude-opus-4-8"))
    }

    @Test func adjacentMinorsAreDistinctInThePalette() {
        let opus = ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8"]
        #expect(Set(opus.compactMap { hex($0) }).count == opus.count)
    }
}
