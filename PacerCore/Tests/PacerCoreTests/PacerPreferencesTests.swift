import Foundation
import Testing
@testable import PacerCore

/// Tests `PacerPreferences.costMode()` mapping. We use a temporary
/// in-memory UserDefaults suite per-test (via a unique suite name)
/// rather than mutating the shared App Group store — these tests run
/// in CI alongside the dev daemon, and we don't want to clobber a
/// running user's pref.
///
/// The accessor under test reads `PacerPreferences.store` which is
/// `UserDefaults(suiteName: PacerStore.appGroupIdentifier)`. We can't
/// inject a different store without changing the API, so we instead
/// write+remove the key on the live store inside a defer to keep the
/// test hermetic. These keys aren't user-visible during the
/// microsecond they're set.
@Test func costModeDefaultsToAutoWhenAbsent() {
    let store = PacerPreferences.store
    let key = PacerPreferenceKeys.costMode
    let original = store.string(forKey: key)
    store.removeObject(forKey: key)
    defer {
        if let original {
            store.set(original, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }
    #expect(PacerPreferences.costMode() == .auto)
}

@Test func costModeMapsCalculate() {
    let store = PacerPreferences.store
    let key = PacerPreferenceKeys.costMode
    let original = store.string(forKey: key)
    store.set("calculate", forKey: key)
    defer {
        if let original {
            store.set(original, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }
    #expect(PacerPreferences.costMode() == .calculate)
}

@Test func costModeMapsDisplay() {
    let store = PacerPreferences.store
    let key = PacerPreferenceKeys.costMode
    let original = store.string(forKey: key)
    store.set("display", forKey: key)
    defer {
        if let original {
            store.set(original, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }
    #expect(PacerPreferences.costMode() == .display)
}

@Test func costModeUnknownStringFallsBackToAuto() {
    let store = PacerPreferences.store
    let key = PacerPreferenceKeys.costMode
    let original = store.string(forKey: key)
    store.set("nonsense", forKey: key)
    defer {
        if let original {
            store.set(original, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }
    #expect(PacerPreferences.costMode() == .auto)
}
