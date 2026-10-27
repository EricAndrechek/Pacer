import Foundation
import Testing
@testable import PacerCore
import PacerUI

/// The compare sheet's one list (`ModelBoardList`), from `MeterModelBoard`
/// literals: grouping, the lines it opens with, what a click does, the cap,
/// and every string a row or the list prints.
@Suite("Model board list")
struct ModelBoardListTests {
    typealias Row = MeterModelBoard.Row

    static func row(_ id: String, _ status: MeterModelBoard.Status, pick: Bool = false, drawn: Bool = false) -> Row {
        Row(id: id, name: id, summary: nil, status: status, isPick: pick, drawnByDefault: drawn, complexity: 2)
    }

    /// A board mid-way through a first launch: the pick and the next four
    /// ranked drawn, two models still scoring, one downloading, one with no
    /// history, two well behind.
    static let board = MeterModelBoard(
        windowKey: "five_hour",
        rows: [
            row("arena-a", .ranked(typicalMiss: 1.8, cycles: 24), drawn: true),
            row("kalman-trend", .ranked(typicalMiss: 1.9, cycles: 24), pick: true, drawn: true),
            row("arena-b", .ranked(typicalMiss: 2.4, cycles: 12), drawn: true),
            row("linear-recent", .ranked(typicalMiss: 2.6, cycles: 24), drawn: true),
            row("recent-rate", .ranked(typicalMiss: 3.1, cycles: 24), drawn: true),
            row("saturating", .ranked(typicalMiss: 3.3, cycles: 24)),
            row("arena-c", .scoring(done: 5, total: 8, eta: 15 * 60)),
            row("arena-d", .scoring(done: 1, total: 8, eta: nil)),
            row("arena-net", .downloading(fraction: 0.41)),
            row("diurnal-rate", .unavailable("not enough history yet")),
            row("arena-y", .wellBehind(typicalMiss: 6.2, cycles: 24)),
            row("arena-z", .wellBehind(typicalMiss: 9.0, cycles: 24)),
        ],
        cutFraction: 0.4, spanCycles: 24, progress: .init(done: 62, total: 100, eta: 15 * 60))

    static let engineIds: Set<String> = ["kalman-trend", "linear-recent", "recent-rate", "saturating", "diurnal-rate"]

    // MARK: - Grouping and order

    @Test func wellBehindRowsAreGroupedLastInTheBoardsOrder() {
        let s = ModelBoardList.sections(Self.board)
        #expect(s.main.map(\.id) == ["arena-a", "kalman-trend", "arena-b", "linear-recent", "recent-rate",
                                     "saturating", "arena-c", "arena-d", "arena-net", "diurnal-rate"])
        #expect(s.wellBehind.map(\.id) == ["arena-y", "arena-z"])
        #expect(ModelBoardList.wellBehindTitle(s.wellBehind.count) == "Well behind (2)")
    }

    /// No row is special: the engine's methods sit among the arena's by
    /// their record.
    @Test func engineMethodsAreOrdinaryRows() {
        let ids = ModelBoardList.sections(Self.board).main.map(\.id)
        #expect(ids.firstIndex(of: "kalman-trend")! > ids.firstIndex(of: "arena-a")!)
        #expect(ids.firstIndex(of: "linear-recent")! > ids.firstIndex(of: "arena-b")!)
    }

    @Test func onlyADownloadingModelCannotBeDrawn() {
        let cannot = Self.board.rows.filter { !ModelBoardList.canDraw($0) }.map(\.id)
        #expect(cannot == ["arena-net"])
    }

    /// The legend explains the pick only when a model ranks ahead of it.
    @Test func thePickNotFirstIsSaid() {
        #expect(ModelBoardList.pickIsNotFirst(Self.board))
        var b = Self.board
        b.rows.swapAt(0, 1)
        #expect(!ModelBoardList.pickIsNotFirst(b))
        b.rows = b.rows.map { var r = $0; r.isPick = false; return r }
        #expect(!ModelBoardList.pickIsNotFirst(b))
    }

    // MARK: - Lines

    @Test func theSheetOpensWithThePickAndTheNextFour() {
        #expect(ModelBoardList.defaultLines(Self.board)
            == ["arena-a", "kalman-trend", "arena-b", "linear-recent", "recent-rate"])
    }

    /// More defaults than the cap: the first ten, the pick kept even when it
    /// ranks below them.
    @Test func defaultsPastTheCapKeepThePick() {
        var rows = (0..<14).map { Self.row("m\($0)", .ranked(typicalMiss: Double($0), cycles: 9), drawn: true) }
        rows[12].isPick = true
        let ids = ModelBoardList.defaultLines(MeterModelBoard(windowKey: "w", rows: rows, cutFraction: nil,
                                                              spanCycles: 9, progress: nil))
        #expect(ids.count == ModelBoardList.lineCap)
        #expect(ids == (0..<9).map { "m\($0)" } + ["m12"])
    }

    @Test func thePickIsDrawnLast() {
        let order = ModelBoardList.drawOrder(["recent-rate", "kalman-trend", "arena-a", "unknown"], board: Self.board)
        #expect(order == ["arena-a", "recent-rate", "unknown", "kalman-trend"])
    }

    @Test func untouchedFollowsTheDefaultsAndAClickKeepsItsChoice() {
        var sel = ModelBoardList.LineSelection()
        sel.follow(Self.board, key: "acct|five_hour")
        #expect(sel.ids == ModelBoardList.defaultLines(Self.board))
        #expect(!sel.touched)

        // A refit moves the ranking: an untouched list follows it.
        var next = Self.board
        next.rows = next.rows.map { var r = $0; r.drawnByDefault = r.isPick || r.id == "saturating"; return r }
        sel.follow(next, key: "acct|five_hour")
        #expect(sel.ids == ["kalman-trend", "saturating"])

        // A click: drawn, then kept through the next refit.
        #expect(sel.toggle("arena-c") == .drawn)
        #expect(sel.toggle("kalman-trend") == .hidden)
        sel.follow(Self.board, key: "acct|five_hour")
        #expect(sel.ids == ["saturating", "arena-c"])
        #expect(sel.touched)

        // A model the board stops listing leaves the lines.
        var fewer = Self.board
        fewer.rows.removeAll { $0.id == "arena-c" }
        sel.follow(fewer, key: "acct|five_hour")
        #expect(sel.ids == ["saturating"])

        // Another window or account starts from its defaults.
        sel.follow(Self.board, key: "acct|seven_day")
        #expect(sel.ids == ModelBoardList.defaultLines(Self.board) && !sel.touched)
    }

    @Test func theCapRefusesTheEleventhLine() {
        var sel = ModelBoardList.LineSelection(key: "k")
        for i in 0..<ModelBoardList.lineCap { #expect(sel.toggle("m\(i)") == .drawn) }
        #expect(sel.isFull)
        #expect(sel.toggle("one-more") == .refused)
        #expect(!sel.contains("one-more"))
        // Hiding one makes room.
        #expect(sel.toggle("m3") == .hidden)
        #expect(sel.toggle("one-more") == .drawn)
        #expect(ModelBoardList.capNote == "10 lines at most: hide one to draw another")
        // The on-demand share never refuses what the sheet has room for.
        #expect(ArenaExtraLines.cap >= ModelBoardList.lineCap)
    }

    /// Only arena models the fit does not project are asked for on demand.
    @Test func onDemandIsTheUnprojectedArenaModels() {
        let ids = ["arena-a", "kalman-trend", "arena-b", "diurnal-rate", "arena-c"]
        let asked = ModelBoardList.onDemand(ids, projected: ["arena-a", "kalman-trend"], engineIds: Self.engineIds)
        #expect(asked == ["arena-b", "arena-c"])
    }

    @Test func eachRowsLineState() {
        typealias L = ModelBoardList.LineState
        let state = ModelBoardList.lineState
        #expect(state(false, true, false, nil, nil) == L.hidden)
        #expect(state(true, true, false, nil, nil) == L.drawn)
        #expect(state(true, true, true, .drawn, nil) == L.drawn)
        #expect(state(true, false, true, .computing, nil) == L.computing)
        // Asked for and not answered yet: computing.
        #expect(state(true, false, true, nil, nil) == L.computing)
        #expect(state(true, false, true, .failed("downloading"), nil) == L.noLine("downloading"))
        // An engine method the fit has no line for says why.
        #expect(state(true, false, false, nil, "nothing used yet this cycle") == L.noLine("nothing used yet this cycle"))
        #expect(state(true, false, false, nil, nil) == L.noLine(ArenaExtraLines.noForecast))
    }

    // MARK: - Words

    @Test func eachStatusInTheRightColumn() {
        let text = { ModelBoardList.statusText($0, spanCycles: 24) }
        #expect(text(.ranked(typicalMiss: 1.9, cycles: 24)) == "within ±2%")
        #expect(text(.ranked(typicalMiss: 0.42, cycles: 24)) == "within ±0.4%")
        #expect(text(.ranked(typicalMiss: 2.4, cycles: 12)) == "within ±2% · 12 cycles")
        #expect(text(.wellBehind(typicalMiss: 6.2, cycles: 24)) == "within ±6%")
        #expect(text(.scoring(done: 5, total: 8, eta: 15 * 60)) == "scoring 62% · 15 min left")
        #expect(text(.scoring(done: 1, total: 8, eta: nil)) == "scoring 12%")
        #expect(text(.downloading(fraction: 0.41)) == "downloading 41%")
        #expect(text(.downloading(fraction: nil)) == "downloading")
        #expect(text(.unavailable("not enough history yet")) == "not enough history yet")
        #expect(ModelBoardList.isRecord(.ranked(typicalMiss: 1, cycles: 1)))
        #expect(ModelBoardList.isRecord(.wellBehind(typicalMiss: 1, cycles: 1)))
        #expect(!ModelBoardList.isRecord(.scoring(done: 1, total: 2, eta: nil)))
    }

    @Test func theProgressLine() {
        #expect(ModelBoardList.progressText(.init(done: 62, total: 100, eta: 15 * 60))
            == "Scoring your history: 62% · about 15 min left")
        #expect(ModelBoardList.progressText(.init(done: 346, total: 698, eta: nil)) == "Scoring your history: 49%")
        #expect(ModelBoardList.progressText(.init(done: 0, total: 0, eta: nil)) == "Scoring your history: 0%")
    }

    @Test func timeLeft() {
        #expect(ModelBoardList.remaining(0) == "1 min left")
        #expect(ModelBoardList.remaining(20) == "1 min left")
        #expect(ModelBoardList.remaining(14 * 60 + 1) == "15 min left")
        #expect(ModelBoardList.remaining(89 * 60) == "89 min left")
        #expect(ModelBoardList.remaining(2 * 3600) == "2 hr left")
        #expect(ModelBoardList.remaining(30 * 3600) == "30 hr left")
        #expect(ModelBoardList.remaining(40 * 3600) == "2 days left")
        #expect(ModelBoardList.remaining(-5) == "1 min left")
    }

    /// Rounded down, so a percent reads 100 only when the work is done.
    @Test func percentsRoundDown() {
        #expect(ModelBoardList.percent(done: 999, total: 1000) == 99)
        #expect(ModelBoardList.percent(done: 1000, total: 1000) == 100)
        #expect(ModelBoardList.percent(done: 1200, total: 1000) == 100)
        #expect(ModelBoardList.percent(done: 3, total: 0) == 0)
    }

    @Test func rowNotesAndTooltips() {
        #expect(ModelBoardList.lineNote(.hidden) == nil)
        #expect(ModelBoardList.lineNote(.drawn) == nil)
        #expect(ModelBoardList.lineNote(.computing) == "computing")
        #expect(ModelBoardList.lineNote(.noLine("downloading")) == "can't project yet · downloading")
        #expect(ModelBoardList.rowHelp(.hidden, isFull: false) == "Draw on the chart")
        #expect(ModelBoardList.rowHelp(.hidden, isFull: true) == ModelBoardList.capNote)
        #expect(ModelBoardList.rowHelp(.drawn, isFull: true) == "Remove from the chart")
        #expect(ModelBoardList.rowHelp(.noLine("x"), isFull: false) == "Remove from the chart")
    }
}
