import Foundation
import Testing
@testable import PacerCore

// "Open Pacer at login" was found off with no registration on record and no
// way to tell when it went. These pin what launch does about it: restore a
// registration macOS dropped, but only against a choice the user actually made.

@Suite("Login item launch decision")
struct LoginItemControllerTests {

    @Test func aDroppedRegistrationIsRestoredOnlyWhenTheUserChoseOn() {
        #expect(LoginItemController.decision(choice: true, status: .notRegistered) == .reRegister)
        #expect(LoginItemController.decision(choice: true, status: .notFound) == .reRegister)
        // Never chosen, or chosen off: Pacer does not register on its own.
        #expect(LoginItemController.decision(choice: nil, status: .notRegistered) == .leave)
        #expect(LoginItemController.decision(choice: false, status: .notRegistered) == .leave)
    }

    /// Waiting on the user in System Settings: registering again would only
    /// prompt again.
    @Test func awaitingApprovalIsLeftToTheUser() {
        #expect(LoginItemController.decision(choice: true, status: .requiresApproval) == .leave)
        #expect(LoginItemController.decision(choice: true, status: .enabled) == .leave)
        #expect(LoginItemController.decision(choice: false, status: .enabled) == .leave)
    }

    /// Set before choices were recorded: adopt what macOS has, so it is
    /// protected from now on without the user flipping it again.
    @Test func anExistingRegistrationWithNoRecordedChoiceIsAdopted() {
        #expect(LoginItemController.decision(choice: nil, status: .enabled) == .adoptAsChoice)
        #expect(LoginItemController.decision(choice: nil, status: .requiresApproval) == .adoptAsChoice)
        #expect(LoginItemController.decision(choice: nil, status: .unknown) == .leave)
    }

    @Test func theToggleReadsOnWhileAwaitingApproval() {
        #expect(LoginItemController.isOn(.enabled))
        #expect(LoginItemController.isOn(.requiresApproval))
        #expect(!LoginItemController.isOn(.notRegistered))
        #expect(!LoginItemController.isOn(.notFound))
    }

    @Test func theChoiceIsRememberedPerStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "pacer.tests.loginItem.\(UUID().uuidString)"))
        #expect(LoginItemController.recordedChoice(in: defaults) == nil)
        LoginItemController.record(true, in: defaults)
        #expect(LoginItemController.recordedChoice(in: defaults) == true)
        LoginItemController.record(false, in: defaults)
        #expect(LoginItemController.recordedChoice(in: defaults) == false)
    }
}
