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

    /// Every `@Model` type the app registers. Single-sourced so the
    /// on-disk container (`makeModelContainer`) and the in-memory one
    /// (`makeInMemoryContainer`, used by the screenshot/demo mode)
    /// can't drift apart — a `@Query` against a model missing from the
    /// container's schema is a hard crash, so both builders must list
    /// the exact same set.
    ///
    /// All targets (Pacer app, PacerWidgets) open the same on-disk
    /// container, so this list must include every @Model type we want
    /// to read or write anywhere.
    ///
    /// Heartbeat lingers from M1 as our App Group sanity check; it
    /// gets removed when the M6 dashboard takes over verification.
    public static let allModelTypes: [any PersistentModel.Type] = [
        Heartbeat.self,
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
        ForecastModelOutcome.self,
        EngineEvalOutcome.self,
    ]

    public static func makeModelContainer() throws -> ModelContainer {
        let url = try storeURL()
        let configuration = ModelConfiguration(url: url)
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
        return try ModelContainer(
            for: Schema(allModelTypes),
            configurations: configuration
        )
    }

    /// In-memory container carrying the full schema. Never touches the
    /// on-disk App Group store, so it's safe to spin up alongside a
    /// running Pacer and seed with synthetic data — used by the
    /// screenshot/demo mode (`PACER_SCREENSHOT_MODE`) to render the real
    /// views against fake data without reading or mutating the user's
    /// actual usage history.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Schema(allModelTypes),
            configurations: configuration
        )
    }
}
