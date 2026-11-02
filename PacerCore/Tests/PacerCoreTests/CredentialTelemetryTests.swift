import Foundation
import Testing
@testable import PacerCore

@Suite("Credential error telemetry", .serialized)
struct CredentialTelemetryTests {

    @Test("every Desktop failure maps to a fixed word")
    func desktopKinds() {
        #expect(DesktopOAuthError.configNotFound.telemetryKind == "config_not_found")
        #expect(DesktopOAuthError.keychainKeyUnavailable(-25300).telemetryKind == "key_unavailable")
        #expect(DesktopOAuthError.keychainAccessDenied.telemetryKind == "access_denied")
        #expect(DesktopOAuthError.decryptFailed("/Users/x/secret path").telemetryKind == "decrypt_failed")
        #expect(DesktopOAuthError.noProfileToken.telemetryKind == "no_profile_token")
    }

    @Test("keychain reasons are reduced to a kind, never carried")
    func keychainKinds() {
        #expect(CredentialTelemetry.keychainKind(reason: "access denied") == "access_denied")
        #expect(CredentialTelemetry.keychainKind(reason: "could not run security (2)") == "spawn_failed")
        #expect(CredentialTelemetry.keychainKind(reason: "security exited 44") == "exit_nonzero")
        #expect(CredentialTelemetry.keychainKind(reason: "who knows") == "other")
    }

    @Test("noteOnce tallies a failure once per launch")
    func once() {
        CredentialTelemetry.resetLaunchState()
        _ = TelemetryCounters.drain()
        CredentialTelemetry.noteOnce("switcher", "usage_unreadable")
        CredentialTelemetry.noteOnce("switcher", "usage_unreadable")
        #expect(TelemetryCounters.drain()["cred.switcher.usage_unreadable"] == 1)
    }

    @Test("a non-empty switcher file that yields nothing is tallied; an absent or empty one is not")
    func switcherFile() throws {
        CredentialTelemetry.resetLaunchState()
        _ = TelemetryCounters.drain()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pacer-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = SwitcherUsageCache.read(at: dir.appendingPathComponent("missing.json"))
        let empty = dir.appendingPathComponent("empty.json")
        try Data().write(to: empty)
        _ = SwitcherUsageCache.read(at: empty)
        #expect(TelemetryCounters.drain().isEmpty)
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{\"layout\": 2}".utf8).write(to: bad)
        _ = SwitcherUsageCache.read(at: bad)
        #expect(TelemetryCounters.drain()["cred.switcher.usage_unreadable"] == 1)
    }

    @Test("a lane is stalled only when polled before, still valid, and not cooling down")
    func stalledLanes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-45 * 60)
        let recent = now.addingTimeInterval(-5 * 60)
        let n = OAuthPoller.stalledLaneCount(
            lastPolledAt: [old, recent, nil, old, old],
            expiresAt: [nil, nil, nil, now.addingTimeInterval(-60), nil],
            cooldownUntil: [nil, nil, nil, nil, now.addingTimeInterval(600)],
            now: now)
        #expect(n == 1)
    }
}
