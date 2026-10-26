import Foundation
@testable import PacerCore

/// The forecast arena's port fixtures (`ArenaFixtures/`, from
/// `research/arena`'s `arena port-fixtures`; format
/// `pacer-arena-port-fixture/1`, described in
/// `research/arena/docs/port-spec.md` § Parity). Synthetic inputs, and what
/// the Python reference made of them: a port passes when it reproduces those
/// outputs within the spec's tolerances.
enum ArenaFixtures {
    struct CaseFile: Decodable {
        let format: String
        let seed: Int
        let cases: [Case]
    }

    struct Case: Decodable {
        let id: String
        let inputs: Inputs
        let request: Request
    }

    struct Inputs: Decodable {
        let account: String
        let window_kind: String
        let scope_model: String?
        let history_start: Int64
        let tz_offset_min: Int?
        let readings: Readings
        let turns: Turns?
    }

    struct Readings: Decodable {
        let t_event: [Int64]
        let t_known: [Int64]
        let util_pct: [Double?]
        let resets_at: [Int64?]
        let state: [String]
    }

    struct Turns: Decodable {
        let t_event: [Int64]
        let t_known: [Int64]
        let family: [String]
        let cost_micro_usd: [Int64?]
    }

    struct Request: Decodable {
        let key: String
        let target: String
        let account: String
        let now: Int64
        let reset_at: Int64
        let grid: [Int64]
    }

    struct ModelFile: Decodable {
        let format: String
        let model: String
        let outputs: [Output]
    }

    struct Output: Decodable {
        let `case`: String
        let levels: [Double]
        let quantiles: [[Double]]
        let median: [Double]
        let exact: Bool
        let mc_paths: Int?
        let mc_bounds: Bounds?
        let detail: JSONValue?
    }

    struct Bounds: Decodable {
        let lo: [[Double]]
        let hi: [[Double]]
    }

    static func url(_ name: String) throws -> URL {
        guard let u = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "ArenaFixtures") else {
            throw ArenaError.invalid("fixture \(name).json not in the test bundle")
        }
        return u
    }

    static func cases(_ name: String = "cases") throws -> CaseFile {
        try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: url(name)))
    }

    static func model(_ name: String) throws -> ModelFile {
        try JSONDecoder().decode(ModelFile.self, from: Data(contentsOf: url(name)))
    }

    /// The case as the port sees it (port-spec § "How a Swift test uses
    /// them", step 2): its rows, its time zone (not the test machine's), and
    /// the history cut at the case's `now` from `history_start`.
    static func history(_ c: Case) -> ArenaHistory {
        let r = c.inputs.readings
        let readings = r.t_event.indices.map { i in
            ArenaReading(tEvent: r.t_event[i], tKnown: r.t_known[i], utilPct: r.util_pct[i],
                         resetsAt: r.resets_at[i], active: r.state[i] == "active")
        }
        let meter = ArenaMeterID(account: c.inputs.account, windowKind: c.inputs.window_kind,
                                 scopeModel: c.inputs.scope_model)
        var spend: [String: [ArenaSpendRow]] = [:]
        if let t = c.inputs.turns {
            spend[c.inputs.account] = t.t_event.indices.map { i in
                ArenaSpendRow(tEvent: t.t_event[i], tKnown: t.t_known[i], family: t.family[i],
                              costUSD: t.cost_micro_usd[i].map { Double($0) * 1e-6 })
            }
        }
        let store = ArenaHistoryStore(meters: [meter: readings], spend: spend,
                                      tzOffsetMin: c.inputs.tz_offset_min, dataStart: c.inputs.history_start)
        return ArenaHistory(store: store, now: c.request.now, accounts: [c.inputs.account],
                            start: c.inputs.history_start)
    }

    static func request(_ c: Case) -> ArenaRequest {
        let target = ArenaTarget(rawValue: c.request.target)!
        let tr = ArenaTargetRequest(key: c.request.key, target: target, accounts: [c.request.account],
                                    grid: c.request.grid, cap: c.inputs.scope_model, resetAt: c.request.reset_at)
        return ArenaRequest(now: c.request.now, accounts: [c.request.account], targets: [tr])
    }
}

/// Any JSON value, for the fixtures' free-form `detail`.
enum JSONValue: Decodable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    subscript(_ key: String) -> JSONValue? { if case .object(let o) = self { o[key] } else { nil } }
    subscript(_ i: Int) -> JSONValue? { if case .array(let a) = self, a.indices.contains(i) { a[i] } else { nil } }
    var number: Double? { if case .number(let d) = self { d } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var numbers: [Double?]? { array?.map(\.number) }
}
