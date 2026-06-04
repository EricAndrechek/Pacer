import Foundation
import Security
import SwiftData

public enum PacerStoreError: Error, Sendable {
    case appGroupContainerUnavailable(identifier: String)
}

public enum PacerStore {
    /// The maintainer's canonical TeamID-prefixed App Group identifier.
    /// Used as the fallback when the running binary's entitlement can't
    /// be read (e.g. the unit-test runner) and as the value the
    /// published build is signed with. The legacy `group.` prefix
    /// triggers the macOS Sequoia App Management prompt on every launch;
    /// `<TeamID>.<bundleid>` does not. See `docs/research/tcc-app-management.md`.
    static let defaultAppGroupIdentifier = "YZXWMJ5VBY.com.ericandrechek.pacer"

    /// Live App Group identifier, derived once from the running binary's
    /// `com.apple.security.application-groups` entitlement. Deriving it
    /// (rather than hardcoding the Team ID) means a contributor who
    /// builds under their *own* Apple Developer account — `dev-install.sh`
    /// templates the entitlements with their Team ID — gets a matching
    /// `<TheirTeamID>.com.ericandrechek.pacer` container with no source
    /// edits. Falls back to `defaultAppGroupIdentifier` when no
    /// entitlement is present. Must match the entitlements files.
    /// See CONTRIBUTING "Building and running it yourself".
    public static let appGroupIdentifier: String = resolveAppGroupIdentifier()

    private static func resolveAppGroupIdentifier() -> String {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ),
              let groups = value as? [String],
              !groups.isEmpty
        else {
            return defaultAppGroupIdentifier
        }
        // Pick the Pacer group by suffix so an unrelated group added to
        // the entitlements later wouldn't silently win the `first` slot.
        return groups.first { $0.hasSuffix(".com.ericandrechek.pacer") } ?? groups[0]
    }
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
            AlertRule.self,
            configurations: configuration
        )
    }
}
