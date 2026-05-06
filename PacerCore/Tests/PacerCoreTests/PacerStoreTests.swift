import Foundation
import SwiftData
import Testing
@testable import PacerCore

@Test func appGroupIdentifierIsStable() {
    #expect(PacerStore.appGroupIdentifier == "group.com.ericandrechek.pacer")
}

@Test func storeFileNameIsStable() {
    #expect(PacerStore.storeFileName == "pacer.sqlite")
}
