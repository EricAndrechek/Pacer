import Foundation
import Testing
@testable import PacerCore

/// Tests `PacerPreferences.costMode(from:)` mapping. We pass an
/// isolated `UserDefaults(suiteName:)` per test so concurrent test
/// execution can't race on the live App Group store.
private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "pacer.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    // Brand-new suites can be polluted by lingering values from
    // earlier processes; clean every key to be safe.
    for (key, _) in defaults.dictionaryRepresentation() {
        defaults.removeObject(forKey: key)
    }
    return defaults
}

@Test func costModeDefaultsToAutoWhenAbsent() {
    let defaults = makeIsolatedDefaults()
    #expect(PacerPreferences.costMode(from: defaults) == .auto)
}

@Test func costModeMapsCalculate() {
    let defaults = makeIsolatedDefaults()
    defaults.set("calculate", forKey: PacerPreferenceKeys.costMode)
    #expect(PacerPreferences.costMode(from: defaults) == .calculate)
}

@Test func costModeMapsDisplay() {
    let defaults = makeIsolatedDefaults()
    defaults.set("display", forKey: PacerPreferenceKeys.costMode)
    #expect(PacerPreferences.costMode(from: defaults) == .display)
}

@Test func costModeUnknownStringFallsBackToAuto() {
    let defaults = makeIsolatedDefaults()
    defaults.set("nonsense", forKey: PacerPreferenceKeys.costMode)
    #expect(PacerPreferences.costMode(from: defaults) == .auto)
}
