import Foundation

/// The per-category cost columns every rollup carries (#296), and the one way
/// to write them.
///
/// `costComponents`' setter writes the five columns AND the row's total, the
/// total being their sum. Nothing else writes a rollup's total, so "the
/// components sum to the total on every row" is true by construction rather
/// than by two running sums happening to agree.
public protocol RollupCostColumns: AnyObject {
    /// The row's total column — `totalCostUSD`, or `cumulativeCostUSD` on the
    /// session rollups.
    var rollupTotalCostUSD: Double { get set }
    var costInput: Double { get set }
    var costOutput: Double { get set }
    var costCacheRead: Double { get set }
    var costCacheWrite5m: Double { get set }
    var costCacheWrite1h: Double { get set }
}

public extension RollupCostColumns {
    var costComponents: CostComponents {
        get {
            CostComponents(
                input: costInput, output: costOutput, cacheRead: costCacheRead,
                cacheWrite5m: costCacheWrite5m, cacheWrite1h: costCacheWrite1h)
        }
        set {
            costInput = newValue.input
            costOutput = newValue.output
            costCacheRead = newValue.cacheRead
            costCacheWrite5m = newValue.cacheWrite5m
            costCacheWrite1h = newValue.cacheWrite1h
            rollupTotalCostUSD = newValue.total
        }
    }
}

extension DailyAggregate: RollupCostColumns {
    public var rollupTotalCostUSD: Double { get { totalCostUSD } set { totalCostUSD = newValue } }
}
extension HourlyAggregate: RollupCostColumns {
    public var rollupTotalCostUSD: Double { get { totalCostUSD } set { totalCostUSD = newValue } }
}
extension ProjectDailyAggregate: RollupCostColumns {
    public var rollupTotalCostUSD: Double { get { totalCostUSD } set { totalCostUSD = newValue } }
}
extension SessionInfo: RollupCostColumns {
    public var rollupTotalCostUSD: Double { get { cumulativeCostUSD } set { cumulativeCostUSD = newValue } }
}
extension AccountDailyAggregate: RollupCostColumns {
    public var rollupTotalCostUSD: Double { get { totalCostUSD } set { totalCostUSD = newValue } }
}
extension AccountHourlyAggregate: RollupCostColumns {
    public var rollupTotalCostUSD: Double { get { totalCostUSD } set { totalCostUSD = newValue } }
}
extension AccountProjectDailyAggregate: RollupCostColumns {
    public var rollupTotalCostUSD: Double { get { totalCostUSD } set { totalCostUSD = newValue } }
}
extension AccountSessionInfo: RollupCostColumns {
    public var rollupTotalCostUSD: Double { get { cumulativeCostUSD } set { cumulativeCostUSD = newValue } }
}
