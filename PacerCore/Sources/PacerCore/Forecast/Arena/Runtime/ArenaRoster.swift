import Foundation

// Which arena models compete for which rate-limit window, and what the app
// calls them.
//
// The engine's own roster is the curve fits in `BurnTrajectory.defaultModels`
// plus the diurnal model; a ported arena model joins it for every window whose
// meter it forecasts. Everything that enumerates the rate-limit roster (the
// engine's complexities, the compare sheet's known models, the record pass,
// the model gallery) reads it from here, so a model that is registered in
// `ArenaRegistry` competes everywhere at once and nowhere it can't run.

/// One engine window in the arena's terms: whose meter, which target, and the
/// scoped cap's model name (`export/readings.py::_scope_model`).
public struct ArenaWindowBinding: Sendable, Hashable {
    public let account: String
    /// The engine's window key: `five_hour`, `seven_day`, or a scoped
    /// `limits[]` identity (`kind|model|surface`).
    public let windowKey: String
    public let target: ArenaTarget
    /// The arena's `scope_model` (`meter.scoped` only).
    public let cap: String?

    public init(account: String, windowKey: String, target: ArenaTarget, cap: String?) {
        self.account = account; self.windowKey = windowKey; self.target = target; self.cap = cap
    }

    public var meter: ArenaMeterID {
        ArenaMeterID(account: account, windowKind: target.windowKind, scopeModel: cap)
    }

    /// The binding for an engine window, or nil when no arena target covers it
    /// (a per-model cap that isn't weekly, a cap that names no model).
    public static func make(account: String, window: WindowSpec) -> ArenaWindowBinding? {
        switch window.origin {
        case .fixed(.fiveHour):
            return ArenaWindowBinding(account: account, windowKey: window.key, target: .meterFiveHour, cap: nil)
        case .fixed(.sevenDay):
            return ArenaWindowBinding(account: account, windowKey: window.key, target: .meterSevenDay, cap: nil)
        case let .scoped(identity, _, _, display, _):
            // The arena reads only `weekly_scoped` caps as scoped meters; the
            // account-wide `session` / `weekly_all` twins never become windows
            // here (`EngineFeatures.isModelScoped`).
            guard identity.split(separator: "|", omittingEmptySubsequences: false).first == "weekly_scoped",
                  let cap = ArenaHistoryBuilder.scopeModel(identity: identity, display: display)
            else { return nil }
            return ArenaWindowBinding(account: account, windowKey: window.key, target: .meterScoped, cap: cap)
        }
    }
}

/// The arena models the engine may pick, from a registry.
public struct ArenaRoster: Sendable {
    /// Every registered model, helpers included (a parent's children must be
    /// reachable through the runner even when they can't be picked).
    public let registry: [ArenaModelSpec]
    /// The ones that compete for a window.
    public let selectable: [ArenaModelSpec]

    public init(registry: [ArenaModelSpec]) {
        self.registry = registry
        self.selectable = registry.filter(Self.isSelectable)
    }

    /// What the app runs: every ported model.
    public static var standard: ArenaRoster { ArenaRoster(registry: ArenaRegistry.all) }
    public static let empty = ArenaRoster(registry: [])

    // MARK: - Who can be picked

    /// Models that exist to be children, never to be shown. The engine's own
    /// methods ported as arena models (`port-engine-*`) are the very curve
    /// fits already in the roster under their app ids, and a Timestral spend
    /// head (`fm-*-spend`) forecasts spend, not a meter, for the ensembles
    /// above it.
    public static let nonSelectablePrefixes = ["port-engine-"]
    /// Exact names that are helpers only. Empty today: a port marks itself
    /// with `selectable = false` in its config instead, which needs no edit
    /// here.
    public static let nonSelectableNames: Set<String> = []

    public static func isSelectable(_ spec: ArenaModelSpec) -> Bool {
        if nonSelectableNames.contains(spec.name) { return false }
        if nonSelectablePrefixes.contains(where: { spec.name.hasPrefix($0) }) { return false }
        if spec.name.hasPrefix("fm-") && spec.name.hasSuffix("-spend") { return false }
        if spec.config.bool("selectable", true) == false { return false }
        return !spec.targets.isEmpty
    }

    /// The selectable models that forecast `target`, in registry order.
    public func specs(for target: ArenaTarget) -> [ArenaModelSpec] {
        selectable.filter { $0.targets.contains(target) }
    }

    public func spec(_ name: String) -> ArenaModelSpec? { registry.first { $0.name == name } }

    /// Every selectable id, for "is this an arena model" checks.
    public var selectableIds: Set<String> { Set(selectable.map(\.name)) }

    public var isEmpty: Bool { selectable.isEmpty }

    public var complexities: [String: Int] {
        Dictionary(selectable.map { ($0.name, $0.complexity) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The rate-limit roster as one list: the engine's methods first, then the
/// arena's. The single place a caller enumerates it.
public enum RateLimitRoster {
    /// The engine's own methods: the curve fits and the diurnal model. These
    /// are scored on the engine actor (`EngineSelfEval.newOutcomesRL`).
    public static var engineIds: [String] { BurnTrajectory.defaultModels.map(\.id) + [DiurnalBurnModel.methodId] }

    public static var engineComplexities: [String: Int] {
        var c = Dictionary(uniqueKeysWithValues: BurnTrajectory.defaultModels.map { ($0.id, $0.complexity) })
        c[DiurnalBurnModel.methodId] = 3
        return c
    }

    /// Complexity of every method that can be picked, the arena's included,
    /// for `EngineSelfEval.bestMethod`'s near-tie break.
    public static func complexities(arena: ArenaRoster) -> [String: Int] {
        engineComplexities.merging(arena.complexities) { engine, _ in engine }
    }

    /// Every method that competes on a window: the engine's, then the
    /// selectable arena models that forecast its meter.
    public static func ids(window: WindowSpec, arena: ArenaRoster) -> [String] {
        guard let target = arenaTarget(window: window) else { return engineIds }
        return engineIds + arena.specs(for: target).map(\.name)
    }

    /// The arena target an engine window's meter is, ignoring whose it is.
    public static func arenaTarget(window: WindowSpec) -> ArenaTarget? {
        ArenaWindowBinding.make(account: "", window: window)?.target
    }
}

extension DiurnalBurnModel {
    /// `id` without an instance (it needs a fitted rate table).
    public static let methodId = "diurnal-rate"
}

// MARK: - Names

/// What the compare sheet and the model gallery call an arena model: the
/// outcome it describes, not the folder it came from. Built from the name's
/// parts, so a model ported later has a sensible label without an edit here.
public enum ArenaModelNames {

    public static func displayName(_ id: String) -> String? {
        if id.hasPrefix("calib-") {
            guard let base = displayName(String(id.dropFirst("calib-".count))) else { return nil }
            return base + ", calibrated range"
        }
        if id.hasPrefix("port-engine-") {
            let method = String(id.dropFirst("port-engine-".count))
            let name = BurnTrajectory.displayName(method)
            return name == method ? nil : name
        }
        if id == "naive-flat" { return "Stays where it is" }
        if id == "naive-linear-to-reset" { return "Average pace so far, held" }
        let size = sizeToken(id).map { " (\($0))" } ?? ""
        if id.hasPrefix("spend-decay-") { return "Recent spend, fading" + lookback(id) }
        if id.contains("timestral") || id.contains("weekly-209m") || id.contains("weekly-28m") {
            return "Pretrained network" + size
        }
        if id.contains("analog") { return "Past moments like now" }
        if id.contains("burst") && (id.contains("mix") || id.contains("pool")) { return "Bursts of use, blended" }
        if id.contains("burst") { return "Bursts of use, simulated" }
        if id.contains("fmgate") { return "Networks, gated by record" }
        if id.hasPrefix("fm-") { return "Pretrained network" + size }
        if id.contains("-fm") { return "Pretrained networks, combined" }
        if id.hasPrefix("ml-gbm") { return "Boosted trees" }
        if id.hasPrefix("ml-qrf") { return "Quantile forest" }
        if id.hasPrefix("combo-") || ["ens", "mix", "stack", "blend", "final", "combo", "pool", "router"]
            .contains(where: { id.contains($0) }) { return "Several forecasters, blended" }
        return nil
    }

    public static func summary(_ id: String) -> String? {
        if id.hasPrefix("calib-") {
            guard let base = summary(String(id.dropFirst("calib-".count))) else { return nil }
            return base + " Its range is retuned on its own past misses."
        }
        if id.hasPrefix("port-engine-") {
            return BurnTrajectory.summary(String(id.dropFirst("port-engine-".count)))
        }
        if id == "naive-flat" { return "The meter stays at its latest reading until the reset." }
        if id.hasPrefix("spend-decay-") {
            return "Turns your recent spend into meter points at your own rate, with the pace fading toward the reset."
        }
        if id.contains("timestral") || id.contains("weekly-209m") || id.contains("weekly-28m") || id.hasPrefix("fm-") {
            return "A network pretrained on many time series reads this window's readings and continues them."
        }
        if id.contains("analog") { return "Finds past moments that looked like now and follows what happened next." }
        if id.contains("burst") { return "Simulates your bursts of use and quiet spells until the reset." }
        if id.contains("fmgate") || id.contains("-fm") {
            return "Several pretrained networks, weighted by how each did on your past cycles."
        }
        if id.hasPrefix("ml-") { return "A model trained on your past cycles' shape and pace." }
        if displayName(id) != nil { return "Several forecasters, weighted by how each did on your past cycles." }
        return nil
    }

    /// "5M", "123M", "209M" from a name.
    static func sizeToken(_ id: String) -> String? {
        for part in id.split(separator: "-") {
            guard part.hasSuffix("m"), part.count >= 2, part.dropLast().allSatisfy(\.isNumber) else { continue }
            return part.dropLast().uppercased() + "M"
        }
        return nil
    }

    /// " (30 min)", " (6 hr)" from `spend-decay-30m` / `-6h` / `-1d`.
    static func lookback(_ id: String) -> String {
        guard let last = id.split(separator: "-").last, let unit = last.last,
              let n = Int(last.dropLast()) else { return "" }
        switch unit {
        case "m": return " (\(n) min)"
        case "h": return " (\(n) hr)"
        case "d": return n == 1 ? " (1 day)" : " (\(n) days)"
        default: return ""
        }
    }
}
