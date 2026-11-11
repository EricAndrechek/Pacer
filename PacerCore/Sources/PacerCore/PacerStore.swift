import CoreData
import Foundation
import Security
import SwiftData

public enum PacerStoreError: Error, Sendable, LocalizedError {
    case appGroupContainerUnavailable(identifier: String)
    /// The store on disk was written by a different schema, and this caller
    /// is not the one that migrates it. See `openWithoutMigrating(at:types:)`.
    case migrationPending

    public var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable(let identifier):
            return "The App Group container \(identifier) is unavailable."
        case .migrationPending:
            return "Pacer is updating its data. Try again in a moment."
        }
    }
}

/// How the store on disk relates to the schema this build carries, read from
/// the store's metadata without opening (or writing) it.
public enum StoreSchemaState: String, Sendable, Equatable {
    /// No store file yet: opening creates an empty one, which is quick.
    case absent
    /// Written by this schema: opening is an ordinary open.
    case current
    /// Written by another schema: opening migrates it in place, which takes
    /// as long as the store is big.
    case needsMigration = "needs-migration"
    /// The metadata could not be read. Opening may migrate, or fail.
    case unknown
}

/// What `PacerStore.prepareStore(at:types:)` did.
public struct StorePreparation: Sendable {
    /// The open container. `ModelContainer` is `Sendable`, so a container
    /// opened off the main thread can be handed to it.
    public let container: ModelContainer
    public let before: StoreSchemaState
    public let after: StoreSchemaState
    public let seconds: Double
    public let onMainThread: Bool

    /// An open that started from another schema and left the store on this
    /// one: SwiftData migrated it.
    public var migrated: Bool { before != .current && before != .absent && after == .current }
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

    /// The cached reader container (see `_cachedContainer`). Never migrates:
    /// see `openWithoutMigrating(at:types:)`. A refused or failed open is not
    /// cached, so the next call tries again.
    public static func sharedModelContainer() throws -> ModelContainer {
        containerLock.lock()
        defer { containerLock.unlock() }
        if let cached = _cachedContainer { return cached }
        let new = try openWithoutMigrating(at: try storeURL())
        _cachedContainer = new
        return new
    }

    /// Open the store, unless opening it would migrate it.
    ///
    /// The app migrates the store, off its main thread, at the first launch
    /// after an update (`prepareStore`). Everything else that opens it reads
    /// it: the widget extension (another process), and the App Intents and
    /// HTTP API inside the app. If one of those opened a store still on the
    /// old schema, SwiftData would start a second in-place migration of the
    /// same file, racing the app's: from the widget, two processes altering
    /// the same tables; in the app, a migration on whatever thread asked,
    /// which for an App Intent is the main one. So they wait their turn
    /// instead: this throws `migrationPending`, the widget draws its
    /// not-fresh state, and the app's next scan cycle reloads the widget's
    /// timelines once the store is ready.
    ///
    /// Only a definite `needsMigration` holds the open back. Metadata that
    /// cannot be read opens as before, so a check that cannot decide never
    /// leaves the widget blank.
    public static func openWithoutMigrating(
        at url: URL, types: [any PersistentModel.Type] = allModelTypes
    ) throws -> ModelContainer {
        if schemaState(at: url, types: types) == .needsMigration {
            throw PacerStoreError.migrationPending
        }
        return try makeModelContainer(at: url, types: types)
    }

    /// Compare the store's metadata with the schema `types` describes.
    ///
    /// SwiftData has no API for "would opening this migrate it?", but it is
    /// Core Data underneath: the store records each entity's version hash,
    /// and `NSManagedObjectModel.makeManagedObjectModel(for:)` builds the
    /// model SwiftData would open it with. Reads the metadata only, so it is
    /// safe beside a process that has the store open, and cheap enough for
    /// the main thread at launch.
    public static func schemaState(
        at url: URL, types: [any PersistentModel.Type] = allModelTypes
    ) -> StoreSchemaState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: types),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: url)
        else { return .unknown }
        return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
            ? .current : .needsMigration
    }

    /// Open the store on the calling thread, migrating it in place first if
    /// the schema changed. Call it off the main thread: the migration takes
    /// as long as the store is big, and it is the first launch after every
    /// schema change that pays it (Sentry PACER-J, #376: 2+ s on the main
    /// thread when this ran inside `PacerAppDelegate.init`).
    ///
    /// Returns the container rather than closing it for a second open on the
    /// main thread: `ModelContainer` is `Sendable`, and that second open would
    /// put the ordinary open's cost back on the main thread for nothing.
    public static func prepareStore(
        at url: URL, types: [any PersistentModel.Type] = allModelTypes
    ) throws -> StorePreparation {
        let began = Date()
        let onMain = Thread.isMainThread
        let before = schemaState(at: url, types: types)
        let container = try makeModelContainer(at: url, types: types)
        // Checked again, rather than assumed: "now current" in the log is the
        // evidence that the metadata check and SwiftData agree, and the widget
        // relies on that agreement (`openWithoutMigrating`).
        let after = schemaState(at: url, types: types)
        return StorePreparation(container: container, before: before, after: after,
                                seconds: Date().timeIntervalSince(began),
                                onMainThread: onMain)
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
        UsageLimitSample.self,
        SessionInfo.self,
        ClaudeCodeMeta.self,
        JSONLFileCursor.self,
        ProjectPathAlias.self,
        ProjectPathProbe.self,
        ProjectBudget.self,
        ProjectCollection.self,
        ProjectMeta.self,
        AlertRule.self,
        ForecastModelOutcome.self,
        EngineEvalOutcome.self,
        PredictionSnapshot.self,
        TokenLaneMeta.self,
        Account.self,
        AccountUsageArchive.self,
        AccountActivation.self,
        AccountDailyAggregate.self,
        AccountHourlyAggregate.self,
        AccountProjectDailyAggregate.self,
        AccountSessionInfo.self,
        PriceRecord.self,
        SpendMeterFit.self,
        LiveMeterOutcome.self,
    ]

    public static func makeModelContainer() throws -> ModelContainer {
        try makeModelContainer(at: try storeURL())
    }

    /// The on-disk container at an explicit path — for tools that verify a
    /// frozen *copy* of a real store and must never open the live one.
    public static func makeModelContainer(at url: URL) throws -> ModelContainer {
        try makeModelContainer(at: url, types: allModelTypes)
    }

    /// `types` is a test seam: a migration test needs a store written by a
    /// schema the app no longer has.
    static func makeModelContainer(
        at url: URL, types: [any PersistentModel.Type]
    ) throws -> ModelContainer {
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
            for: Schema(types),
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
