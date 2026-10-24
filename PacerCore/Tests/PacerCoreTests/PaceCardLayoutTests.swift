import AppKit
import SwiftUI
import Testing
@testable import PacerUI

// #161: the pace card keeps its columns in one container at every count.
// Two halves: that the new container lays every arrangement out exactly as
// the old `HStack` / `PaceColumnGrid` / `VStack`-of-grids branches did, frame
// for frame, and that a column's `@State` survives the arrangement changing,
// which the old branches did not.
//
// Measured off-screen, an `NSHostingView` never put in a window, with
// stand-in columns: the real `PaceColumn` lives in the app target. The
// stand-ins are sized the way it is (full width, leading, heights that
// differ and text that wraps) so rows and stacks have something to align.

@MainActor
@Suite("Pace card layout", .serialized)
struct PaceCardLayoutTests {

    // MARK: - Arrangement and slots

    @Test("two windows are a pair, more are a grid, several accounts are grouped")
    func arrangement() {
        #expect(PaceCardArrangement(columnCount: 2, accountCount: 1) == .pair)
        #expect(PaceCardArrangement(columnCount: 1, accountCount: 1) == .pair)
        #expect(PaceCardArrangement(columnCount: 0, accountCount: 0) == .pair)
        // The count decides first, as the card's first branch did.
        #expect(PaceCardArrangement(columnCount: 2, accountCount: 2) == .pair)
        #expect(PaceCardArrangement(columnCount: 3, accountCount: 1) == .grid)
        #expect(PaceCardArrangement(columnCount: 6, accountCount: 1) == .grid)
        #expect(PaceCardArrangement(columnCount: 4, accountCount: 2) == .grouped)
        #expect(PaceCardArrangement(columnCount: 3, accountCount: 2) == .grouped)
    }

    @Test("a pair is column, rule, column; a grid the columns; grouped a header before each account")
    func slots() {
        #expect(PaceCardSlot.slots(.pair, accounts: [("a", ["a|5h", "a|7d"])])
                == [.column(id: "a|5h"), .rule, .column(id: "a|7d")])
        #expect(PaceCardSlot.slots(.pair, accounts: [("a", ["a|5h"])]) == [.column(id: "a|5h")])
        #expect(PaceCardSlot.slots(.pair, accounts: []) == [])
        #expect(PaceCardSlot.slots(.grid, accounts: [("a", ["a|5h", "a|7d", "a|opus"])])
                == [.column(id: "a|5h"), .column(id: "a|7d"), .column(id: "a|opus")])
        #expect(PaceCardSlot.slots(.grouped, accounts: [("a", ["a|5h", "a|7d"]), ("b", ["b|5h", "b|7d", "b|opus"])])
                == [.header(account: "a"), .column(id: "a|5h"), .column(id: "a|7d"),
                    .header(account: "b"), .column(id: "b|5h"), .column(id: "b|7d"), .column(id: "b|opus")])
    }

    @Test("a column's slot, its identity in the ForEach, is the same in every arrangement")
    func slotIdentityIsArrangementFree() {
        let accounts: [(account: String, columns: [String])] = [("a", ["a|5h", "a|7d"])]
        for arrangement in [PaceCardArrangement.pair, .grid, .grouped] {
            #expect(PaceCardSlot.slots(arrangement, accounts: accounts).contains(.column(id: "a|5h")))
        }
    }

    @Test("children split into account runs at each header")
    func runs() {
        typealias Run = PaceAccountGroupsLayout.Run
        #expect(PaceAccountGroupsLayout.runs(isHeader: [true, false, false, true, false])
                == [Run(header: 0, columns: 1..<3), Run(header: 3, columns: 4..<5)])
        #expect(PaceAccountGroupsLayout.runs(isHeader: [false, false]) == [Run(header: nil, columns: 0..<2)])
        #expect(PaceAccountGroupsLayout.runs(isHeader: [false, true, false])
                == [Run(header: nil, columns: 0..<1), Run(header: 1, columns: 2..<3)])
        #expect(PaceAccountGroupsLayout.runs(isHeader: [true]) == [Run(header: 0, columns: 1..<1)])
        #expect(PaceAccountGroupsLayout.runs(isHeader: []) == [])
    }

    // MARK: - Harness

    static let space = "paceCard"

    final class FrameLog {
        var frames: [String: CGRect] = [:]
        func record(_ id: String, _ frame: CGRect) { frames[id] = frame }
    }

    struct Col: Identifiable {
        let id: String
        let height: CGFloat
    }

    struct Account: Identifiable {
        let id: String
        let columns: [Col]
    }

    static func cell(_ col: Col, _ log: FrameLog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window \(col.id), a title long enough to wrap in a narrow column")
                .font(.system(size: 12))
            Color.gray.frame(height: col.height)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Probe(id: col.id, log: log))
    }

    static func header(_ account: String, _ log: FrameLog) -> some View {
        HStack(spacing: 8) {
            Text("Account \(account)").font(.system(size: 11, weight: .semibold))
            Text("Max 20×").font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .background(Probe(id: "header|\(account)", log: log))
    }

    /// Records its frame in the card's space whenever it is laid out.
    struct Probe: View {
        let id: String
        let log: FrameLog
        var body: some View {
            GeometryReader { proxy in
                let _ = log.record(id, proxy.frame(in: .named(PaceCardLayoutTests.space)))
                Color.clear
            }
        }
    }

    /// The card's three branches before #161, verbatim but for the stand-ins.
    struct OldCard: View {
        let accounts: [Account]
        let log: FrameLog
        var body: some View {
            let cols = accounts.flatMap(\.columns)
            if cols.count <= 2 {
                HStack(alignment: .top, spacing: 24) {
                    PaceCardLayoutTests.cell(cols[0], log)
                    Divider().frame(height: 110)
                    PaceCardLayoutTests.cell(cols[1], log)
                }
            } else if accounts.count > 1 {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(accounts) { account in
                        VStack(alignment: .leading, spacing: 10) {
                            PaceCardLayoutTests.header(account.id, log)
                            PaceColumnGrid() {
                                ForEach(account.columns) { PaceCardLayoutTests.cell($0, log) }
                            }
                        }
                    }
                }
            } else {
                PaceColumnGrid() {
                    ForEach(cols) { PaceCardLayoutTests.cell($0, log) }
                }
            }
        }
    }

    struct NewCard: View {
        let accounts: [Account]
        let log: FrameLog
        var body: some View {
            PaceCardColumns(accounts: accounts.map { (id: $0.id, columns: $0.columns) }) { account in
                PaceCardLayoutTests.header(account, log)
            } cell: { col, _ in
                PaceCardLayoutTests.cell(col, log)
            }
        }
    }

    struct Measured<Content: View>: View {
        let width: CGFloat
        let content: Content
        var body: some View {
            content
                .frame(width: width, alignment: .topLeading)
                .coordinateSpace(.named(PaceCardLayoutTests.space))
        }
    }

    static func settle(_ host: NSView) {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
    }

    static func layOut(_ view: some View, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: Measured(width: width, content: view))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        settle(host)
        return size
    }

    static func account(_ id: String, _ heights: [CGFloat]) -> Account {
        let windows = ["5h", "7d", "opus", "sonnet", "design", "weekly"]
        return Account(id: id, columns: heights.enumerated().map { index, height in
            Col(id: "\(id)|\(windows[index])", height: height)
        })
    }

    // MARK: - Same frames as the old branches

    static let cases: [(name: String, accounts: [Account])] = [
        ("pair", [account("a", [120, 150])]),
        // Shorter than the rule, so the rule's 110 pt sets the card's height.
        ("pair, short", [account("a", [40, 60])]),
        ("grid of 3", [account("a", [120, 150, 90])]),
        ("grid of 4", [account("a", [120, 150, 90, 130])]),
        ("grid of 5", [account("a", [120, 150, 90, 130, 100])]),
        ("grid of 6", [account("a", [120, 150, 90, 130, 100, 140])]),
        ("two accounts, fixed pair each", [account("a", [120, 150]), account("b", [110, 100])]),
        ("two accounts, 3 + 2", [account("a", [120, 150, 90]), account("b", [110, 100])]),
        ("three accounts", [account("a", [120, 150]), account("b", [110, 100, 95]),
                            account("c", [130, 125, 80, 140])]),
    ]

    @Test("every arrangement lays out frame for frame as the old branches did",
          arguments: [1000, 700, 560, 300] as [CGFloat])
    func sameFramesAsOldBranches(width: CGFloat) {
        for (name, accounts) in Self.cases {
            let old = FrameLog(), new = FrameLog()
            let oldSize = Self.layOut(OldCard(accounts: accounts, log: old), width: width)
            let newSize = Self.layOut(NewCard(accounts: accounts, log: new), width: width)
            let expected = accounts.flatMap(\.columns).count + (accounts.count > 1 ? accounts.count : 0)
            #expect(old.frames.count == expected, "\(name) @ \(width): the harness measured every child")
            #expect(Set(new.frames.keys) == Set(old.frames.keys), "\(name) @ \(width)")
            #expect(abs(newSize.width - oldSize.width) < 0.001 && abs(newSize.height - oldSize.height) < 0.001,
                    "\(name) @ \(width): card \(newSize) vs \(oldSize)")
            for (id, was) in old.frames {
                guard let now = new.frames[id] else { continue }
                #expect(Self.same(now, was), "\(name) @ \(width): \(id) at \(now), was \(was)")
            }
        }
    }

    @Test("the pair's rule stands where the old divider did", arguments: [1000, 560, 300] as [CGFloat])
    func ruleMatchesOldDivider(width: CGFloat) {
        let old = FrameLog(), new = FrameLog()
        let a = Col(id: "a|5h", height: 40), b = Col(id: "a|7d", height: 60)
        let oldSize = Self.layOut(HStack(alignment: .top, spacing: 24) {
            Self.cell(a, old)
            Divider().frame(height: 110).background(Probe(id: "rule", log: old))
            Self.cell(b, old)
        }, width: width)
        let newSize = Self.layOut(PaceCardArrangement.pair.layout {
            Self.cell(a, new)
            PaceCardRule().background(Probe(id: "rule", log: new))
            Self.cell(b, new)
        }, width: width)
        #expect(oldSize == newSize)
        let was = old.frames["rule"], now = new.frames["rule"]
        #expect(was != nil && now != nil)
        if let was, let now { #expect(Self.same(now, was), "rule at \(now), was \(was)") }
        // Upright: a rule's width, not a share of the row's.
        #expect((now?.width ?? .infinity) < 4)
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    // MARK: - A column's state survives the arrangement changing

    final class BirthLog {
        var births: [String: UUID] = [:]
        func record(_ id: String, _ birth: UUID) { births[id] = birth }
    }

    /// A column with `@State`, as `PaceColumn` has its hover and share state:
    /// a new identity starts with a new `born`.
    struct StatefulCell: View {
        let id: String
        let log: BirthLog
        @State private var born = UUID()
        var body: some View {
            let _ = log.record(id, born)
            Color.gray.frame(height: 40).frame(maxWidth: .infinity)
        }
    }

    struct StatefulRoot: View {
        let accounts: [Account]
        let old: Bool
        let log: BirthLog
        var body: some View {
            if old {
                // The old branches, cut down to their containers.
                let cols = accounts.flatMap(\.columns)
                if cols.count <= 2 {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(cols) { StatefulCell(id: $0.id, log: log) }
                    }
                } else if accounts.count > 1 {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(accounts) { account in
                            PaceColumnGrid() {
                                ForEach(account.columns) { StatefulCell(id: $0.id, log: log) }
                            }
                        }
                    }
                } else {
                    PaceColumnGrid() { ForEach(cols) { StatefulCell(id: $0.id, log: log) } }
                }
            } else {
                PaceCardColumns(accounts: accounts.map { (id: $0.id, columns: $0.columns) }) { account in
                    Text(account)
                } cell: { col, _ in
                    StatefulCell(id: col.id, log: log)
                }
            }
        }
    }

    /// The 5-hour column's birth through: the fixed pair, a scoped window
    /// arriving (grid), a second account's first reading (grouped), and both
    /// going away again (pair).
    static func birthsThroughArrangements(old: Bool) -> [UUID?] {
        let log = BirthLog()
        let steps: [[Account]] = [
            [account("a", [40, 40])],
            [account("a", [40, 40, 40])],
            [account("a", [40, 40, 40]), account("b", [40, 40])],
            [account("a", [40, 40])],
        ]
        let host = NSHostingView(rootView: StatefulRoot(accounts: steps[0], old: old, log: log))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        var births: [UUID?] = []
        for step in steps {
            host.rootView = StatefulRoot(accounts: step, old: old, log: log)
            settle(host)
            births.append(log.births["a|5h"])
        }
        return births
    }

    @Test("a column keeps its state as windows and accounts come and go")
    func stateSurvivesArrangementChanges() {
        let births = Self.birthsThroughArrangements(old: false)
        #expect(births.count == 4 && births.allSatisfy { $0 != nil })
        #expect(Set(births.compactMap { $0 }).count == 1, "the 5-hour column was rebuilt: \(births)")
    }

    @Test("the harness sees the reset the old branches caused")
    func oldBranchesResetState() {
        // Without this the test above could pass by never rebuilding anything.
        let births = Self.birthsThroughArrangements(old: true)
        #expect(births.allSatisfy { $0 != nil })
        #expect(Set(births.compactMap { $0 }).count > 1)
    }
}
