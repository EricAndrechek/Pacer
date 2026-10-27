import Foundation
import PacerCore

/// The compare sheet's model list as plain logic: how a `MeterModelBoard` is
/// grouped, which lines are drawn and how a click changes them, and what each
/// row says. Every model is a row of the same kind, the engine's methods and
/// the arena's alike; the sheet draws it and nothing here knows about views,
/// so all of it is tested without one.
public enum ModelBoardList {

    /// Lines on the chart at once, at most. Past ten, the dashed lines stop
    /// being told apart.
    public static let lineCap = 10

    // MARK: - Grouping

    /// The list, in the board's order: every row but the well-behind ones,
    /// then those, under their own collapsed heading.
    public struct Sections: Equatable, Sendable {
        public var main: [MeterModelBoard.Row]
        public var wellBehind: [MeterModelBoard.Row]
    }

    public static func sections(_ board: MeterModelBoard) -> Sections {
        var s = Sections(main: [], wellBehind: [])
        for row in board.rows {
            if case .wellBehind = row.status { s.wellBehind.append(row) } else { s.main.append(row) }
        }
        return s
    }

    /// Whether a row can have a line: everything but a model whose network
    /// is still downloading.
    public static func canDraw(_ row: MeterModelBoard.Row) -> Bool {
        if case .downloading = row.status { return false }
        return true
    }

    /// The pick, when the board has one.
    public static func pick(_ board: MeterModelBoard) -> MeterModelBoard.Row? { board.rows.first(where: \.isPick) }

    /// Whether a model ranks ahead of the pick: the near-tie rule picked the
    /// simpler of models that close, which the legend then says.
    public static func pickIsNotFirst(_ board: MeterModelBoard) -> Bool {
        guard let pick = pick(board),
              let first = board.rows.first(where: { if case .ranked = $0.status { true } else { false } })
        else { return false }
        return first.id != pick.id
    }

    // MARK: - Lines

    /// The lines the sheet opens with: the board's `drawnByDefault` rows, in
    /// its order, the pick always among them when there are more than the cap.
    public static func defaultLines(_ board: MeterModelBoard) -> [String] {
        let wanted = board.rows.filter { $0.drawnByDefault && canDraw($0) }
        guard wanted.count > lineCap else { return wanted.map(\.id) }
        let pickId = wanted.first(where: \.isPick)?.id
        var others = lineCap - (pickId == nil ? 0 : 1)
        return wanted.compactMap { row in
            if row.id == pickId { return row.id }
            guard others > 0 else { return nil }
            others -= 1
            return row.id
        }
    }

    /// The order lines are drawn in: the board's, with the pick last so its
    /// line sits on top.
    public static func drawOrder(_ ids: [String], board: MeterModelBoard) -> [String] {
        let position = Dictionary(board.rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pickId = pick(board)?.id
        return ids.sorted { a, b in
            if (a == pickId) != (b == pickId) { return b == pickId }
            return (position[a] ?? .max, a) < (position[b] ?? .max, b)
        }
    }

    /// The models a sheet draws, for as long as it is open: never persisted.
    /// The board's ranking and pick move with every refit, and a saved set
    /// would keep yesterday's choices on today's list. Until the first click
    /// it follows the board's defaults, so a list still filling in redraws
    /// its best few as they settle; after it, it keeps the clicks.
    public struct LineSelection: Equatable, Sendable {
        /// The window and account the lines belong to.
        public private(set) var key: String
        /// The drawn models, in the order they were turned on.
        public private(set) var ids: [String] = []
        /// Whether a click has changed them.
        public private(set) var touched = false

        public init(key: String = "") { self.key = key }

        public var isFull: Bool { ids.count >= lineCap }
        public func contains(_ id: String) -> Bool { ids.contains(id) }

        /// Take in a new board. Another window or account starts again from
        /// its defaults; an untouched selection follows them; a touched one
        /// keeps its clicks, less any model the board no longer lists.
        public mutating func follow(_ board: MeterModelBoard, key: String) {
            if key != self.key { self = LineSelection(key: key) }
            if !touched {
                ids = defaultLines(board)
                return
            }
            let listed = Set(board.rows.filter(canDraw).map(\.id))
            ids.removeAll { !listed.contains($0) }
        }

        public enum Toggle: Equatable, Sendable {
            case drawn, hidden
            /// Already `lineCap` lines: nothing changed.
            case refused
        }

        /// Draw a model or stop drawing it.
        @discardableResult
        public mutating func toggle(_ id: String) -> Toggle {
            if let i = ids.firstIndex(of: id) {
                ids.remove(at: i)
                touched = true
                return .hidden
            }
            guard !isFull else { return .refused }
            ids.append(id)
            touched = true
            return .drawn
        }
    }

    /// The drawn models the window's fit does not project itself, which the
    /// sheet asks for on demand (`ArenaExtraLines.sync`): arena models only,
    /// since an engine method's line is the fit's or there is none.
    public static func onDemand(_ ids: [String], projected: Set<String>, engineIds: Set<String>) -> [String] {
        ids.filter { !projected.contains($0) && !engineIds.contains($0) }
    }

    /// Where a row's line stands.
    public enum LineState: Equatable, Sendable {
        case hidden
        case drawn
        /// Asked for; its projection is being made.
        case computing
        /// Asked for, but there is none this cycle, and why.
        case noLine(String)
    }

    /// `hasLine`: the chart has its line. `onDemand`: it is asked for through
    /// `ArenaExtraLines`, whose state is `extras`. `reason`: why the window's
    /// fit has none, for a model it does not ask for.
    public static func lineState(selected: Bool, hasLine: Bool, onDemand: Bool,
                                 extras: ArenaExtraLines.State?, reason: String?) -> LineState {
        guard selected else { return .hidden }
        if hasLine { return .drawn }
        guard onDemand else { return .noLine(reason ?? ArenaExtraLines.noForecast) }
        if case let .failed(why)? = extras { return .noLine(why) }
        return .computing
    }

    // MARK: - Words

    /// What a row says under its name about its line, when it has one to say.
    public static func lineNote(_ state: LineState) -> String? {
        switch state {
        case .hidden, .drawn: return nil
        case .computing: return "computing"
        case let .noLine(reason): return "can't project yet · \(reason)"
        }
    }

    /// A row's tooltip: what a click does.
    public static func rowHelp(_ state: LineState, isFull: Bool) -> String {
        switch state {
        case .hidden: return isFull ? capNote : "Draw on the chart"
        case .drawn, .computing, .noLine: return "Remove from the chart"
        }
    }

    /// Said once the chart has `lineCap` lines.
    public static var capNote: String { "\(lineCap) lines at most: hide one to draw another" }

    /// The collapsed group's heading.
    public static func wellBehindTitle(_ count: Int) -> String { "Well behind (\(count))" }

    /// The right column: the typical miss, or where the model stands.
    /// "within ±2% · 12 cycles" when a record covers fewer than the column's
    /// cycles; "scoring 62% · 15 min left"; "downloading 41%"; the reason a
    /// model has nothing yet.
    public static func statusText(_ status: MeterModelBoard.Status, spanCycles: Int) -> String {
        switch status {
        case let .ranked(miss, cycles), let .wellBehind(miss, cycles):
            return PacerAccuracyFormat.record(miss, partialCycles: cycles < spanCycles ? cycles : nil)
        case let .scoring(done, total, eta):
            return "scoring \(percent(done: done, total: total))%" + (eta.map { " · \(remaining($0))" } ?? "")
        case let .downloading(fraction):
            return fraction.map { "downloading \(percent($0))%" } ?? "downloading"
        case let .unavailable(reason):
            return reason
        }
    }

    /// Whether the right column is a record (a number to compare) rather than
    /// a state; the sheet sets the two apart.
    public static func isRecord(_ status: MeterModelBoard.Status) -> Bool {
        switch status {
        case .ranked, .wellBehind: return true
        case .scoring, .downloading, .unavailable: return false
        }
    }

    /// The line above the list while the scorer works through history:
    /// "Scoring your history: 62% · about 15 min left".
    public static func progressText(_ p: MeterModelBoard.Progress) -> String {
        "Scoring your history: \(percent(done: p.done, total: p.total))%"
            + (p.eta.map { " · about \(remaining($0))" } ?? "")
    }

    /// "15 min left", "2 hr left", "3 days left". Minutes round up, so the
    /// last stretch never reads "0 min".
    public static func remaining(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 90 * 60 { return "\(max(1, Int((s / 60).rounded(.up)))) min left" }
        if s < 36 * 3600 { return "\(Int((s / 3600).rounded())) hr left" }
        let days = Int((s / 86_400).rounded())
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    /// Done over total as a whole percent, rounded down: 100 only when done.
    public static func percent(done: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return percent(Double(done) / Double(total))
    }

    static func percent(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }
}
