import Foundation
import SwiftData
import Testing
@testable import PacerCore

@Test func appGroupIdentifierIsStable() {
    // TeamID-prefixed; legacy "group." prefix triggers the macOS Sequoia
    // App Management prompt on every launch. See PacerStore comment.
    //
    // The maintainer's canonical group id. The live `appGroupIdentifier`
    // is derived from the signed entitlement (so a contributor's own-team
    // build adapts), and the test runner — which carries no app-group
    // entitlement — falls back to exactly this value.
    #expect(PacerStore.defaultAppGroupIdentifier == "YZXWMJ5VBY.com.ericandrechek.pacer")
    #expect(PacerStore.appGroupIdentifier == "YZXWMJ5VBY.com.ericandrechek.pacer")
}

@Test func legacyAppGroupIdentifierIsStable() {
    // Migration source; only read by LegacyContainerMigrator on first
    // launch with the new container name.
    #expect(PacerStore.legacyAppGroupIdentifier == "group.com.ericandrechek.pacer")
}

@Test func storeFileNameIsStable() {
    #expect(PacerStore.storeFileName == "pacer.sqlite")
}
