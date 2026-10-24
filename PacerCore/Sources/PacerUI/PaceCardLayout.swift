import SwiftUI

// The rate-limit pace card's one container for every column count (#161).
//
// The card used to pick a container by count: an `HStack` for the fixed
// 5-hour and 7-day pair, a `PaceColumnGrid` for one account's three or more
// windows, and a `VStack` of per-account headers and grids for several
// accounts. Those were `if`/`else` branches around the same columns, so each
// branch was a different identity. A scoped per-model window appearing, or a
// second account's first reading, moved every column into another branch:
// SwiftUI rebuilt them all, each column's hover was lost and an open share
// popover closed under the cursor.
//
// Now every column sits in one `ForEach`, keyed by its own id, under one
// `AnyLayout`, which is SwiftUI's way to change a layout without changing
// the identity of what it lays out. Each arrangement is the container it
// replaces: the same `HStackLayout`, the same `PaceColumnGrid`, and for
// several accounts `PaceAccountGroupsLayout`, the two `VStack`s' arithmetic.
// `PaceCardLayoutTests` measures every arrangement against the old
// containers.

/// How the pace card arranges its columns.
public enum PaceCardArrangement: Sendable, Equatable {
    /// Two windows at most (one account's fixed 5-hour and 7-day): side by
    /// side with a rule between, never wrapping.
    case pair
    /// One account with more than two windows: the balanced grid.
    case grid
    /// Several accounts: each account's header, then its windows in a grid.
    case grouped

    /// The order matters: two windows are a pair even if two accounts
    /// reported them, as the card's first branch always was.
    public init(columnCount: Int, accountCount: Int) {
        if columnCount <= 2 {
            self = .pair
        } else if accountCount > 1 {
            self = .grouped
        } else {
            self = .grid
        }
    }

    /// The spacing of the old pair `HStack`.
    static let pairSpacing: CGFloat = 24

    /// The layout for this arrangement, over `PaceCardSlot.slots`' children.
    var layout: AnyLayout {
        switch self {
        case .pair:    return AnyLayout(HStackLayout(alignment: .top, spacing: Self.pairSpacing))
        case .grid:    return AnyLayout(PaceColumnGrid())
        case .grouped: return AnyLayout(PaceAccountGroupsLayout())
        }
    }
}

/// One child of the card's layout. A column's slot is its id alone, the same
/// in every arrangement, which is what keeps its view (and its `@State`)
/// when the arrangement changes.
enum PaceCardSlot: Hashable, Sendable, Identifiable {
    case header(account: String)
    case column(id: String)
    case rule

    var id: Self { self }

    /// The children in the order their arrangement lays them out: a pair is
    /// column, rule, column; a grid is the columns; grouped is each
    /// account's header followed by its columns.
    static func slots(_ arrangement: PaceCardArrangement,
                      accounts: [(account: String, columns: [String])]) -> [PaceCardSlot] {
        switch arrangement {
        case .pair:
            // At most two columns, so at most one rule.
            var out: [PaceCardSlot] = []
            for id in accounts.flatMap(\.columns) {
                if !out.isEmpty { out.append(.rule) }
                out.append(.column(id: id))
            }
            return out
        case .grid:
            return accounts.flatMap(\.columns).map { .column(id: $0) }
        case .grouped:
            return accounts.flatMap { account -> [PaceCardSlot] in
                [.header(account: account.account)] + account.columns.map { .column(id: $0) }
            }
        }
    }
}

/// The rule between the two columns of a pair: the old `HStack`'s divider.
///
/// A `Divider` runs across the stack it is in, and it is upright here only
/// because the pair's `AnyLayout` wraps an `HStackLayout`. Lying flat it
/// would take a share of the pair's width; `PaceCardLayoutTests` checks it
/// stands where the old one did.
struct PaceCardRule: View {
    var body: some View {
        Divider().frame(height: 110)
    }
}

/// Several accounts' windows: each account's header, then its windows in a
/// `PaceColumnGrid`, the accounts stacked. The children are each header
/// (marked `paceAccountHeader()`) followed by its account's columns.
///
/// What `VStack(alignment: .leading, spacing: 18)` of
/// `VStack(alignment: .leading, spacing: 10) { header; grid }` did, as one
/// layout, so the columns are its own children rather than a nested grid's.
public struct PaceAccountGroupsLayout: Layout {
    /// The gap between accounts, and under each account's header.
    static let accountSpacing: CGFloat = 18
    static let headerSpacing: CGFloat = 10

    public init() {}

    /// Marks an account's header, where its run of columns starts.
    struct IsHeader: LayoutValueKey {
        static let defaultValue = false
    }

    private var grid: PaceColumnGrid { PaceColumnGrid() }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                             cache: inout ()) -> CGSize {
        var size = CGSize.zero
        stack(width: proposal.width, subviews: subviews) { _, frame in
            size.width = max(size.width, frame.width)
            size.height = frame.maxY
        }
        return size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                              subviews: Subviews, cache: inout ()) {
        stack(width: bounds.width, subviews: subviews) { part, frame in
            let at = frame.offsetBy(dx: bounds.minX, dy: bounds.minY)
            switch part {
            case .header(let index):
                subviews[index].place(at: at.origin, anchor: .topLeading,
                                      proposal: ProposedViewSize(at.size))
            case .columns(let range):
                var none: () = ()
                grid.placeSubviews(in: at, proposal: ProposedViewSize(width: at.width, height: nil),
                                   subviews: subviews[range], cache: &none)
            }
        }
    }

    enum Part: Equatable {
        case header(Int)
        case columns(Range<Int>)
    }

    /// The parts top to bottom, each at the leading edge, offered the full
    /// width and sized by its own ideal height, as the stacks did. Frames
    /// are relative to the layout's origin.
    private func stack(width: CGFloat?, subviews: Subviews, _ visit: (Part, CGRect) -> Void) {
        let offered = ProposedViewSize(width: width, height: nil)
        var y: CGFloat = 0
        for (index, run) in Self.runs(isHeader: subviews.map { $0[IsHeader.self] }).enumerated() {
            if index > 0 { y += Self.accountSpacing }
            if let header = run.header {
                let size = subviews[header].sizeThatFits(offered)
                visit(.header(header), CGRect(origin: CGPoint(x: 0, y: y), size: size))
                y += size.height
                if !run.columns.isEmpty { y += Self.headerSpacing }
            }
            if !run.columns.isEmpty {
                var none: () = ()
                let size = grid.sizeThatFits(proposal: offered, subviews: subviews[run.columns],
                                             cache: &none)
                visit(.columns(run.columns), CGRect(origin: CGPoint(x: 0, y: y), size: size))
                y += size.height
            }
        }
    }

    struct Run: Equatable {
        var header: Int?
        var columns: Range<Int>
    }

    /// Splits the children into account runs: a header and the columns up to
    /// the next header. Columns before any header are a run without one.
    static func runs(isHeader: [Bool]) -> [Run] {
        var out: [Run] = []
        var index = 0
        while index < isHeader.count {
            let header: Int? = isHeader[index] ? index : nil
            let start = header == nil ? index : index + 1
            var end = start
            while end < isHeader.count, !isHeader[end] { end += 1 }
            out.append(Run(header: header, columns: start..<end))
            index = end
        }
        return out
    }
}

public extension View {
    /// Marks an account's header among `PaceAccountGroupsLayout`'s children.
    func paceAccountHeader() -> some View {
        layoutValue(key: PaceAccountGroupsLayout.IsHeader.self, value: true)
    }
}

/// The pace card's columns, arranged by how many there are and how many
/// accounts they come from, in one container whatever the count.
///
/// - `accounts`: each account's id and its columns, in the order the card
///   shows them.
/// - `header`: an account's header, drawn only when there are several.
/// - `cell`: one column, told the arrangement it is drawn in.
public struct PaceCardColumns<Column: Identifiable, Header: View, Cell: View>: View
where Column.ID == String {
    let accounts: [(id: String, columns: [Column])]
    let header: (String) -> Header
    let cell: (Column, PaceCardArrangement) -> Cell

    public init(accounts: [(id: String, columns: [Column])],
                @ViewBuilder header: @escaping (String) -> Header,
                @ViewBuilder cell: @escaping (Column, PaceCardArrangement) -> Cell) {
        self.accounts = accounts
        self.header = header
        self.cell = cell
    }

    public var body: some View {
        let arrangement = PaceCardArrangement(
            columnCount: accounts.reduce(0) { $0 + $1.columns.count },
            accountCount: accounts.count)
        let slots = PaceCardSlot.slots(arrangement, accounts: accounts.map {
            (account: $0.id, columns: $0.columns.map(\.id))
        })
        // Ids are unique by construction (account and window); keeping the
        // first is only so a duplicate could never trap.
        let byId = Dictionary(accounts.flatMap(\.columns).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        arrangement.layout {
            ForEach(slots) { slot in
                switch slot {
                case .header(let account):
                    header(account).paceAccountHeader()
                case .column(let id):
                    if let column = byId[id] { cell(column, arrangement) }
                case .rule:
                    PaceCardRule()
                }
            }
        }
    }
}
