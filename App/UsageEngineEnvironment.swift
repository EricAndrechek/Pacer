import SwiftUI
import PacerCore

/// Carries the shared `UsageIntelligenceEngine` down the view tree so cards can
/// `ask` it. The engine is a plain background actor (not `@Observable`), so the
/// typed `@Environment(Type.self)` form doesn't apply — a classic
/// `EnvironmentKey` does. Injected once at the scene root from the
/// `AppBackgroundService` that owns it; `nil` by default so previews/tests that
/// don't inject one simply render the warming-up state.
private struct UsageEngineKey: EnvironmentKey {
    static let defaultValue: UsageIntelligenceEngine? = nil
}

/// The per-scope engines. A view that follows the account scope resolves its
/// own here; `usageEngine` remains the all-accounts instance for everything
/// that must not follow the window.
private struct UsageEngineHostKey: EnvironmentKey {
    // A `let` of an optional class type is already Sendable, so this needs no
    // `nonisolated(unsafe)`. The host itself is `@MainActor`, and every read of
    // this key happens in a view body, which is too.
    static let defaultValue: EngineHost? = nil
}

extension EnvironmentValues {
    var usageEngine: UsageIntelligenceEngine? {
        get { self[UsageEngineKey.self] }
        set { self[UsageEngineKey.self] = newValue }
    }

    var usageEngines: EngineHost? {
        get { self[UsageEngineHostKey.self] }
        set { self[UsageEngineHostKey.self] = newValue }
    }
}
