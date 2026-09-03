import Foundation
import Testing
@testable import PacerCore

private func account(
    id: String = "org-1",
    displayName: String = "Claude account (max)",
    email: String? = nil,
    orgName: String? = nil
) -> Account {
    Account(id: id, organizationId: id, displayName: displayName,
            isActive: true, firstSeenAt: .distantPast, lastSeenAt: .distantPast,
            emailAddress: email, organizationName: orgName)
}

@Suite("Account labels")
struct AccountLabelTests {

    @Test("email wins when we have one")
    func emailIsPreferred() {
        #expect(account(email: "a@example.com", orgName: "Acme").label == "a@example.com")
    }

    @Test("org name is the fallback before the placeholder")
    func orgNameBeatsPlaceholder() {
        #expect(account(orgName: "Acme").label == "Acme")
    }

    @Test("the derived placeholder is still better than a raw uuid")
    func placeholderBeatsId() {
        #expect(account().label == "Claude account (max)")
    }

    @Test("an empty display name falls through to the id rather than showing blank")
    func emptyNameFallsThroughToId() {
        #expect(account(displayName: "").label == "org-1")
    }

    @Test("empty strings are treated as absent, not as a label")
    func emptyStringsAreNotLabels() {
        #expect(account(email: "", orgName: "").label == "Claude account (max)")
    }

    @Test("auto-derived names are recognised so a rename is never clobbered")
    func derivedNamesAreRecognised() {
        #expect(account(displayName: "Claude account (max20x)").hasDerivedName)
        #expect(account(displayName: "Account 8f7d").hasDerivedName)
        #expect(account(displayName: "Primary account").hasDerivedName)
        #expect(account(displayName: "").hasDerivedName)
        #expect(account(displayName: "Work").hasDerivedName == false)
    }
}

@Suite("External account directory")
struct ExternalAccountDirectoryTests {

    private func writeRoster(_ json: String) throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let dir = home.appendingPathComponent(".claude-swap-backup")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("sequence.json"),
                       atomically: true, encoding: .utf8)
        return home
    }

    @Test("a claude-swap roster yields one entry per account, keyed by org")
    func readsClaudeSwapRoster() throws {
        let home = try writeRoster("""
        {"activeAccountNumber":2,"accounts":{
          "1":{"email":"work@example.com","uuid":"u1","organizationUuid":"org-work",
               "organizationName":"Work Org"},
          "2":{"email":"me@example.com","uuid":"u2","organizationUuid":"org-personal",
               "organizationName":"Personal Org"}}}
        """)
        let directory = ExternalAccountDirectory.discover(homeDirectory: home)
        #expect(directory.entries.count == 2)
        #expect(directory.entries["org-work"]?.emailAddress == "work@example.com")
        #expect(directory.entries["org-personal"]?.organizationName == "Personal Org")
        #expect(directory.entries["org-work"]?.source == "claude-swap slot 1")
    }

    @Test("an account with no org uuid is skipped, not keyed on an empty string")
    func skipsEntriesWithoutAnOrg() throws {
        let home = try writeRoster("""
        {"accounts":{"1":{"email":"a@example.com","organizationUuid":""},
                     "2":{"email":"b@example.com","organizationUuid":"org-2"}}}
        """)
        let directory = ExternalAccountDirectory.discover(homeDirectory: home)
        #expect(directory.entries.count == 1)
        #expect(directory.entries["org-2"]?.emailAddress == "b@example.com")
    }

    @Test("no switcher installed is an empty directory, not a failure")
    func missingRosterIsEmpty() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        #expect(ExternalAccountDirectory.discover(homeDirectory: home).isEmpty)
    }

    @Test("malformed json is ignored rather than crashing the scan")
    func malformedRosterIsIgnored() throws {
        let home = try writeRoster("{ not json at all")
        #expect(ExternalAccountDirectory.discover(homeDirectory: home).isEmpty)
    }
}
