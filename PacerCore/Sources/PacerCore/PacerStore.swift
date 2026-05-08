import Foundation
import SwiftData

public enum PacerStoreError: Error, Sendable {
    case appGroupContainerUnavailable(identifier: String)
}

public enum PacerStore {
    /// TeamID-prefixed App Group identifier. The legacy `group.` prefix
    /// triggers the macOS Sequoia App Management prompt on every launch;
    /// `<TeamID>.<bundleid>` does not. Must match the entitlements files.
    /// See `docs/research/tcc-app-management.md`.
    public static let appGroupIdentifier = "YZXWMJ5VBY.com.ericandrechek.pacer"
    /// Pre-rename identifier. Only ever used by `bin/dev-install.sh` to
    /// copy SwiftData + UserDefaults from the legacy Group Container on
    /// upgrade. No first-release end-user has data here.
    public static let legacyAppGroupIdentifier = "group.com.ericandrechek.pacer"
    public static let storeFileName = "pacer.sqlite"

    public static func sharedContainerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw PacerStoreError.appGroupContainerUnavailable(identifier: appGroupIdentifier)
        }
        return url
    }

    public static func storeURL() throws -> URL {
        try sharedContainerURL().appendingPathComponent(storeFileName)
    }

    public static func makeModelContainer() throws -> ModelContainer {
        let url = try storeURL()
        let configuration = ModelConfiguration(url: url)
        // All targets (Pacer app, PacerDaemon, PacerWidgets) open the
        // same on-disk container, so the schema list here must include
        // every @Model type we want to read or write anywhere. Adding a
        // new model means listing it here AND coming up with a
        // migration plan if there's user data in the wild.
        //
        // Heartbeat lingers from M1 as our App Group sanity check; it
        // gets removed when the M6 dashboard takes over verification.
        return try ModelContainer(
            for: Heartbeat.self,
            TokenSample.self,
            DailyAggregate.self,
            ProjectDailyAggregate.self,
            RateLimitSample.self,
            SessionInfo.self,
            ClaudeCodeMeta.self,
            JSONLFileCursor.self,
            configurations: configuration
        )
    }
}
