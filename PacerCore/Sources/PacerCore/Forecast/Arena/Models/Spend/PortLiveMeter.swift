import Foundation

/// `models/port-live-meter/model.py`: what the app shows now, as a forecast:
/// the live meter (#318), flat to reset.
///
/// The centre is `KitSpend.liveDetail(...).shown` (the latest reading plus
/// the spend since it at the fitted points per dollar, floored to whole
/// points with the carry, shown to a tenth); where the app shows no live
/// value it shows the reading, and so does this. The spread is the fit's
/// own error at this much spend: the residuals of the `neighbours`
/// intervals of the 14-day fit whose converted spend was nearest what has
/// been spent since the reading. Each path is one residual, constant over
/// the path, kept between the latest reading and 100.
///
/// The Python draws residuals uniformly with replacement; this port answers
/// with the exact equal-weight type-1 quantiles of those values (no
/// fixture covers this model; the arithmetic is `KitDetQ.weightedType1`'s).
public final class PortLiveMeterModel: ArenaModel {
    let k: Int
    let ctx: ArenaContext
    var history: ArenaHistory?

    public init(context: ArenaContext) {
        k = context.config.int("neighbours", 400)
        ctx = context
    }

    public func fit(_ history: ArenaHistory) { self.history = history }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets {
            try ctx.checkCancelled()
            out[tr.key] = meter(tr)
        }
        return ArenaForecast(byKey: out)
    }

    func meter(_ tr: ArenaTargetRequest) -> ArenaTargetForecast {
        let h = history!
        let m = KitBaselines.meterNow(h, tr)
        let acct = tr.accounts[0]
        let live = KitSpend.liveDetail(h, account: acct, windowKind: m.windowKind, scopeModel: m.scopeModel)
        let centre = live?.shown ?? m.latest
        let added = live?.added ?? 0
        let n = tr.grid.count
        guard KitSpend.fitDetails(h, account: acct, windowKind: m.windowKind, scopeModel: m.scopeModel) != nil,
              let rows = KitSpend.fitRows(h, account: acct, windowKind: m.windowKind, scopeModel: m.scopeModel,
                                          dayStart: KitSpend.localDayStart(h, account: acct)),
              !rows.residuals.isEmpty
        else { return .point([Double](repeating: centre, count: n)) }
        // np.argsort(fitted, kind="stable").
        let order = rows.fitted.indices.sorted {
            rows.fitted[$0] != rows.fitted[$1] ? rows.fitted[$0] < rows.fitted[$1] : $0 < $1
        }
        let fitted = order.map { rows.fitted[$0] }, resid = order.map { rows.residuals[$0] }
        // np.searchsorted(fitted, added) ("left").
        var lo0 = 0, hi0 = fitted.count
        while lo0 < hi0 { let mid = (lo0 + hi0) >> 1; if fitted[mid] < added { lo0 = mid + 1 } else { hi0 = mid } }
        let i = lo0
        // Python's floor division: k // 2.
        let lo = max(0, min(i - k / 2, fitted.count - k))
        let near = Array(resid[lo..<min(lo + k, resid.count)])
        let values = near.map { [min(max(centre + $0, m.latest), 100.0)] }
        let q = KitDetQ.weightedType1(values, weights: [Double](repeating: 1, count: values.count),
                                      levels: KitDetQ.forecastLevels)
        return ArenaTargetForecast(levels: KitDetQ.forecastLevels, quantiles: q.map { [Double](repeating: $0[0], count: n) })
    }
}
