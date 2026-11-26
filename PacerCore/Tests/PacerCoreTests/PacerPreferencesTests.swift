import Foundation
import Testing
@testable import PacerCore

/// Tests `PacerPreferences.costMode(from:)` mapping. We pass an
/// isolated suite (`TestDefaults`) per test so concurrent test
/// execution can't race on the live App Group store.
@Test func costModeDefaultsToAutoWhenAbsent() {
    let holder = TestDefaults()
    defer { holder.cleanup() }
    let defaults = holder.defaults
    #expect(PacerPreferences.costMode(from: defaults) == .auto)
}

@Test func costModeMapsCalculate() {
    let holder = TestDefaults()
    defer { holder.cleanup() }
    let defaults = holder.defaults
    defaults.set("calculate", forKey: PacerPreferenceKeys.costMode)
    #expect(PacerPreferences.costMode(from: defaults) == .calculate)
}

@Test func costModeMapsDisplay() {
    let holder = TestDefaults()
    defer { holder.cleanup() }
    let defaults = holder.defaults
    defaults.set("display", forKey: PacerPreferenceKeys.costMode)
    #expect(PacerPreferences.costMode(from: defaults) == .display)
}

@Test func costModeUnknownStringFallsBackToAuto() {
    let holder = TestDefaults()
    defer { holder.cleanup() }
    let defaults = holder.defaults
    defaults.set("nonsense", forKey: PacerPreferenceKeys.costMode)
    #expect(PacerPreferences.costMode(from: defaults) == .auto)
}

@Test func oauthTokenOverrideAbsentReturnsNil() {
    let holder = TestDefaults()
    defer { holder.cleanup() }
    let defaults = holder.defaults
    #expect(PacerPreferences.oauthTokenOverride(from: defaults) == nil)
}

@Test func oauthTokenOverrideEmptyStringReturnsNil() {
    let holder = TestDefaults()
    defer { holder.cleanup() }
    let defaults = holder.defaults
    defaults.set("", forKey: PacerPreferenceKeys.oauthTokenOverride)
    #expect(PacerPreferences.oauthTokenOverride(from: defaults) == nil)
}

@Test func oauthTokenOverrideWhitespaceOnlyReturnsNil() {
    let holder = TestDefaults()
    defer { holder.cleanup() }
    let defaults = holder.defaults
    defaults.set("   \n  ", forKey: PacerPreferenceKeys.oauthTokenOverride)
    #expect(PacerPreferences.oauthTokenOverride(from: defaults) == nil)
}

@Test func oauthTokenOverrideTrimsWhitespace() {
    let holder = TestDefaults()
    defer { holder.cleanup() }
    let defaults = holder.defaults
    defaults.set("  sk-ant-oat01-abc\n", forKey: PacerPreferenceKeys.oauthTokenOverride)
    #expect(PacerPreferences.oauthTokenOverride(from: defaults) == "sk-ant-oat01-abc")
}
