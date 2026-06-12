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

extension EnvironmentValues {
    var usageEngine: UsageIntelligenceEngine? {
        get { self[UsageEngineKey.self] }
        set { self[UsageEngineKey.self] = newValue }
    }
}
