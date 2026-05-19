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

    /// Process-wide cached container for the widget extension's read
    /// path. Each widget provider used to call `makeModelContainer()`
    /// per refresh; opening the SQLite store + validating schema is a
    /// heavy operation (50–200ms) that has no business firing on every
    /// 5-minute widget refresh. Apple documents `ModelContainer` as
    /// thread-safe and intended to be shared, so caching is a strict
    /// upgrade.
    ///
    /// The app process should keep using `makeModelContainer()`
    /// directly because `PacerAppDelegate` constructs the container
    /// once at startup with explicit ownership semantics — sharing the
    /// same `_cachedContainer` between the app's setup path and a
    /// future widget query path inside the same process would be a
    /// footgun.
    nonisolated(unsafe) private static var _cachedContainer: ModelContainer?
    private static let containerLock = NSLock()

    public static func sharedModelContainer() throws -> ModelContainer {
        containerLock.lock()
        defer { containerLock.unlock() }
        if let cached = _cachedContainer { return cached }
        let new = try makeModelContainer()
        _cachedContainer = new
        return new
    }

    public static func makeModelContainer() throws -> ModelContainer {
        let url = try storeURL()
        let configuration = ModelConfiguration(url: url)
        // All targets (Pacer app, PacerDaemon, PacerWidgets) open the
        // same on-disk container, so the schema list here must include
        // every @Model type we want to read or write anywhere.
        //
        // **Schema evolution:** Pacer relies on SwiftData's implicit
        // lightweight migration — safe for added optional fields and
        // added @Model types. Anything heavier (added NON-optional
        // field without default, removed field, renamed field, type
        // change on an existing field) requires a `VersionedSchema` +
        // `SchemaMigrationPlan` here; otherwise the container open
        // crashes on first launch for users with existing data. The
        // `showFatalContainerError` alert in `PacerAppDelegate` is the
        // user-facing safety net, but the right fix is to add the
        // migration plan before shipping the schema change.
        //
        // Heartbeat lingers from M1 as our App Group sanity check; it
        // gets removed when the M6 dashboard takes over verification.
        return try ModelContainer(
            for: Heartbeat.self,
            TokenSample.self,
            DailyAggregate.self,
            HourlyAggregate.self,
            ProjectDailyAggregate.self,
            RateLimitSample.self,
            ExtraUsageSample.self,
            SessionInfo.self,
            ClaudeCodeMeta.self,
            JSONLFileCursor.self,
            ProjectPathAlias.self,
            ProjectPathProbe.self,
            ProjectBudget.self,
            configurations: configuration
        )
    }
}
