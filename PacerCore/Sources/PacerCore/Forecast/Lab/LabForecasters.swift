import Foundation
import Synchronization

/// External forecasters served by the prediction-lab helper
/// (`research/lab/helper`), so models built in Python can compete in a dev
/// build of the app on the same terms as the built-in roster.
///
/// **Off unless configured.** The engine only looks for a helper when the App
/// Group defaults carry `PacerLabHelperURL` or the process environment carries
/// `PACER_LAB_HELPER`; with neither, nothing here runs and the engine is the one
/// that ships. A test process never reads either (`PacerPreferences.isTestProcess`):
/// an overnight helper on the owner's machine must not leak into `swift test`.
///
/// **How a helper model competes.** Each refit fetches the helper's prediction
/// for the live cycle (one request per window, short timeout) before the
/// synchronous fit, and wraps the answer as a `BurnTrajectory.Model`
/// (`LabForecastModel`) whose line runs straight from the live reading to the
/// predicted final at the reset. From there it is a roster member like any
/// other: the record scores it on completed cycles (live refits take the most
/// recent ones, the full-history pass the rest), selection can pick it once
/// the pass has covered it and while the helper answers (`LabRefit.projecting`),
/// its band is calibrated from its own record, and the compare sheet lists it
/// with the name and text the helper serves.
///
/// Every id the helper serves must start with `lab-` (`idPrefix`), so a helper
/// can never shadow a built-in model and write into its record.
public enum LabHelper {
    /// App Group defaults key holding the helper's base URL, e.g.
    /// `http://127.0.0.1:7231`.
    public static let defaultsKey = "PacerLabHelperURL"
    /// Environment variable with the same meaning; it wins over the defaults.
    public static let environmentKey = "PACER_LAB_HELPER"
    /// Namespace every external model id lives in.
    public static let idPrefix = "lab-"

    /// Whether a model id belongs to the helper's namespace.
    public static func isExternal(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The helper's base URL, or nil when none is configured (the default).
    /// Read on every refit, so setting or clearing it needs no relaunch (a
    /// `defaults write` from a shell can take a moment to reach a running app;
    /// relaunching makes it certain).
    public static func configuredURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = PacerPreferences.store,
        isTestProcess: Bool = PacerPreferences.isTestProcess
    ) -> URL? {
        guard !isTestProcess else { return nil }
        // The README screenshots draw a synthetic fixture; a helper reading the
        // live store would forecast real cycles onto made-up ones. A live
        // render (`PACER_RENDER_LIVE`) reads the real store, as the helper
        // does, and shows what the app shows.
        if environment["PACER_SCREENSHOT_MODE"] == "1", (environment["PACER_RENDER_LIVE"] ?? "").isEmpty {
            return nil
        }
        let raw = environment[environmentKey] ?? defaults.string(forKey: defaultsKey)
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    /// Whether this process has a helper configured.
    public static var isConfigured: Bool { configuredURL() != nil }

    /// Ids a helper may use: the prefix, then letters, digits, `.`, `_`, `-`.
    /// Commas and pipes would break the record keys and the backfill marker.
    static func isValidId(_ id: String) -> Bool {
        guard isExternal(id), id.count > idPrefix.count, id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    /// Complexity a helper model gets when it states none: above every
    /// built-in (Kalman is 5), so on a near-tie the built-in model keeps the
    /// window and a lab model has to actually be better to be shown.
    public static let defaultComplexity = 6
}

/// What the helper says about one of its models (`GET /v1/models`).
public struct LabModelInfo: Sendable, Equatable, Codable {
    public let id: String
    public let displayName: String
    public let summary: String?
    public let howItWorks: String?
    /// Window keys it serves (`five_hour`, `seven_day`, a scoped identity), or
    /// `*` for every window.
    public let windows: [String]
    public let complexity: Int

    public init(id: String, displayName: String, summary: String? = nil, howItWorks: String? = nil,
                windows: [String], complexity: Int = LabHelper.defaultComplexity) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.howItWorks = howItWorks
        self.windows = windows
        self.complexity = complexity
    }

    enum CodingKeys: String, CodingKey { case id, displayName, summary, howItWorks, windows, complexity }

    /// Lenient: a missing name reads as the id, missing windows as none, a
    /// missing complexity as `LabHelper.defaultComplexity`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? id
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        howItWorks = try? c.decodeIfPresent(String.self, forKey: .howItWorks)
        windows = (try? c.decodeIfPresent([String].self, forKey: .windows)) ?? []
        complexity = (try? c.decodeIfPresent(Int.self, forKey: .complexity)) ?? LabHelper.defaultComplexity
    }

    public func serves(_ windowKey: String) -> Bool {
        windows.contains("*") || windows.contains(windowKey)
    }

    /// The models the engine will use: valid ids, each once, serving at least
    /// one window.
    static func usable(_ models: [LabModelInfo]) -> [LabModelInfo] {
        var seen = Set<String>()
        return models.filter { LabHelper.isValidId($0.id) && !$0.windows.isEmpty && seen.insert($0.id).inserted }
    }
}

/// One forecast from a helper model: the final usage it expects at the reset,
/// and optionally its own 80% band. The band is carried, not shown: like every
/// model, a lab model's band comes from the conformal calibration of its own
/// record, so bands stay comparable across the roster.
public struct LabPrediction: Sendable, Equatable {
    public let final: Double
    public let q10: Double?
    public let q90: Double?
    public init(final: Double, q10: Double? = nil, q90: Double? = nil) {
        self.final = final
        self.q10 = q10
        self.q90 = q90
    }
}

/// `POST /v1/forecast`'s body, in its batch form: one window, one account,
/// several cycles, each with the cut instants to forecast at. The helper also
/// accepts the single-cycle form (`cycleStart`/`resetsAt`/`cuts` at the top
/// level); the app always sends `cycles`.
public struct LabForecastRequest: Sendable, Equatable, Encodable {
    public struct Cycle: Sendable, Equatable, Encodable {
        public let cycleStart: Double
        public let resetsAt: Double
        public let cuts: [Double]
        /// The instants as the engine computed them, which answers are keyed
        /// by (`LabKey`): never rebuilt from the wire's doubles.
        let resetDate: Date
        let cutDates: [Date]
        public init(cycleStart: Date, resetsAt: Date, cuts: [Date]) {
            self.cycleStart = cycleStart.timeIntervalSince1970
            self.resetsAt = resetsAt.timeIntervalSince1970
            self.cuts = cuts.map(\.timeIntervalSince1970)
            self.resetDate = resetsAt
            self.cutDates = cuts
        }
        enum CodingKeys: String, CodingKey { case cycleStart, resetsAt, cuts }
    }
    public let window: String
    /// Window length in seconds, so the helper need not know scoped windows.
    public let duration: Double
    public let account: String?
    public let cycles: [Cycle]
    /// The models wanted; the helper runs only these.
    public let models: [String]
    /// After this many milliseconds the helper stops calling predictors and
    /// answers with what it has (the rest null), so one slow model can't cost
    /// the others their answer.
    public let deadlineMs: Int?
}

/// `POST /v1/forecast`'s answer: per cycle (in request order), per model, one
/// entry per cut (in request order), null where the model declined.
public struct LabForecastResponse: Sendable, Equatable {
    public struct Cycle: Sendable, Equatable {
        public let predictions: [String: [LabPrediction?]]
        public init(predictions: [String: [LabPrediction?]]) { self.predictions = predictions }
    }
    public let cycles: [Cycle]
    public init(cycles: [Cycle]) { self.cycles = cycles }
}

extension LabForecastResponse: Decodable {
    private struct WirePrediction: Decodable {
        let final: Double?
        let q10: Double?
        let q90: Double?
    }
    private struct WireCycle: Decodable {
        let predictions: [String: [WirePrediction?]]?
    }
    private enum CodingKeys: String, CodingKey { case cycles }

    /// Lenient per entry: an entry without a finite `final` is a decline, not
    /// a broken response.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let wire = try c.decode([WireCycle].self, forKey: .cycles)
        cycles = wire.map { cycle in
            Cycle(predictions: (cycle.predictions ?? [:]).mapValues { entries in
                entries.map { entry in
                    guard let entry, let final = entry.final, final.isFinite else { return nil }
                    return LabPrediction(final: final,
                                         q10: entry.q10.flatMap { $0.isFinite ? $0 : nil },
                                         q90: entry.q90.flatMap { $0.isFinite ? $0 : nil })
                }
            })
        }
    }
}

/// How the engine reaches a helper. `LabHelperClient` in the app; a stub in tests.
public protocol LabForecastFetching: Sendable {
    func models() async throws -> [LabModelInfo]
    func forecast(_ request: LabForecastRequest) async throws -> LabForecastResponse
}

public enum LabHelperError: Error, Equatable {
    case timedOut
    case badStatus(Int)
    case malformed
}

/// The HTTP client for `research/lab/helper`.
public struct LabHelperClient: LabForecastFetching {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        let cfg = configuration
        // A helper that isn't running must fail now, not after a wait for
        // connectivity; the engine's own timeout bounds the rest.
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
    }

    private struct ModelsEnvelope: Decodable { let models: [LabModelInfo] }

    public func models() async throws -> [LabModelInfo] {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard let envelope = try? JSONDecoder().decode(ModelsEnvelope.self, from: data) else {
            throw LabHelperError.malformed
        }
        return envelope.models
    }

    public func forecast(_ body: LabForecastRequest) async throws -> LabForecastResponse {
        var request = URLRequest(url: baseURL.appending(path: "v1/forecast"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard let decoded = try? JSONDecoder().decode(LabForecastResponse.self, from: data) else {
            throw LabHelperError.malformed
        }
        return decoded
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LabHelperError.badStatus(http.statusCode)
        }
    }
}

/// Names and texts the helper served, for the compare sheet. Process-wide
/// because `BurnTrajectory.displayName` and friends are static; empty (so every
/// lookup falls through to today's behaviour) unless a helper answered.
public final class LabModelCatalog: Sendable {
    public static let shared = LabModelCatalog()
    private let infos = Mutex<[String: LabModelInfo]>([:])

    public init() {}

    /// Adds or replaces these models' metadata. Never removes: a model the
    /// helper stopped serving keeps its name for the record it left.
    public func register(_ models: [LabModelInfo]) {
        infos.withLock { dict in for m in models { dict[m.id] = m } }
    }

    public func info(_ id: String) -> LabModelInfo? { infos.withLock { $0[id] } }

    /// Every lab model id a helper has described this launch, sorted.
    public var ids: [String] { infos.withLock { $0.keys.sorted() } }
}

/// The key a lab prediction is stored and looked up under: the cycle (its reset,
/// to the minute, as the record keys cycles) and the cut instant (to the
/// millisecond, so the same `Date` computed twice finds the same entry).
struct LabKey: Hashable, Sendable {
    let resetMinute: Int64
    let cutMillis: Int64
    init(resetsAt: Date, cut: Date) {
        resetMinute = Int64((resetsAt.timeIntervalSince1970 / 60).rounded())
        cutMillis = Int64((cut.timeIntervalSince1970 * 1000).rounded())
    }
}

/// A helper model as a roster member. `fit` cannot reach the network (it is
/// synchronous and runs many times per refit), so the engine fetches first and
/// hands the answers in: `fit` only looks up the prediction for this cycle and
/// cut, and draws a straight line from the live reading to it at the reset.
struct LabForecastModel: BurnTrajectory.Model {
    let id: String
    let complexity: Int
    let predictions: [LabKey: LabPrediction]
    /// Why it has no line for the live cycle, for the compare sheet.
    let unavailableNote: String

    func prediction(for cycle: BurnTrajectory.PartialCycle) -> LabPrediction? {
        predictions[LabKey(resetsAt: cycle.resetsAt, cut: cycle.now)]
    }

    func fit(_ cycle: BurnTrajectory.PartialCycle) -> (@Sendable (Date) -> Double)? {
        guard let p = prediction(for: cycle), p.final.isFinite else { return nil }
        return Self.line(from: cycle.now, used: cycle.usedNow, to: cycle.resetsAt, final: p.final)
    }

    /// The line through (now, used) and (reset, final). It starts on the live
    /// reading, so `displayedAtReset` adds no anchor and shows `final` clamped
    /// to [used, 100]: the value the model is scored on is the value it named.
    static func line(from now: Date, used: Double, to reset: Date, final: Double) -> @Sendable (Date) -> Double {
        let span = reset.timeIntervalSince(now)
        guard span > 0 else { return { _ in max(used, final) } }
        let slope = (final - used) / span
        return { date in used + slope * date.timeIntervalSince(now) }
    }
}

/// The cut instants the record scores a completed cycle at, as
/// `EngineSelfEval.newOutcomesRL` computes them: only cuts with three readings
/// by then (the record's rule), so nothing is asked that would not be scored.
extension EngineSelfEval {
    static func rlCutInstants(_ cycle: BurnTrajectory.Cycle) -> [Date] {
        let duration = cycle.resetsAt.timeIntervalSince(cycle.cycleStart)
        guard duration > 0 else { return [] }
        return rlCutFractions.compactMap { cf in
            let now = cycle.cycleStart.addingTimeInterval(duration * cf)
            return cycle.samples.filter { $0.at <= now }.count >= 3 ? now : nil
        }
    }

    /// `newOutcomesRL` for helper models: the same cuts, the same three-reading
    /// rule, the same displayed value, the same truth. Kept apart from the
    /// built-in scoring so that path stays exactly what it was, and because a
    /// helper model's only state is the predictions handed to it.
    static func newOutcomesRLExternal(
        window: String,
        cycles: [BurnTrajectory.Cycle],
        models: [any BurnTrajectory.Model],
        existingKeys: Set<String>
    ) -> [NewOutcome] {
        let surface = rlSurface(window)
        var out: [NewOutcome] = []
        for cycle in cycles {
            let trueFinal = cycle.samples.map { $0.usedPercentage }.max() ?? 0
            guard trueFinal > 0 else { continue }
            let periodKey = periodKeyRL(cycle.resetsAt)
            let duration = cycle.resetsAt.timeIntervalSince(cycle.cycleStart)
            guard duration > 0 else { continue }
            for cf in rlCutFractions {
                let now = cycle.cycleStart.addingTimeInterval(duration * cf)
                let seen = cycle.samples.filter { $0.at <= now }
                guard seen.count >= 3 else { continue }
                let partial = BurnTrajectory.PartialCycle(
                    samples: seen, now: now, cycleStart: cycle.cycleStart, resetsAt: cycle.resetsAt)
                let bucket = rlBucket(cf)
                for m in models {
                    let key = EngineEvalOutcome.makeKey(surface: surface, method: m.id, bucket: bucket, periodKey: periodKey)
                    guard !existingKeys.contains(key), let proj = m.fit(partial) else { continue }
                    out.append(NewOutcome(surface: surface, method: m.id, bucket: bucket, periodKey: periodKey,
                                          predicted: BurnTrajectory.displayedAtReset(proj, partial: partial),
                                          truth: trueFinal))
                }
            }
        }
        return out
    }
}

/// Runs `operation`, or throws `LabHelperError.timedOut` once `limit` passes
/// (cancelling it: `URLSession`'s async calls stop on cancellation).
func labWithTimeout<T: Sendable>(
    _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw LabHelperError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw LabHelperError.timedOut }
        return first
    }
}
