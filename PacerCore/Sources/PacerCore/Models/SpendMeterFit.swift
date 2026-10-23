import Foundation
import SwiftData

/// One day's spend → meter conversion for one account and one window (#317):
/// how many points of that window's usage meter one dollar of API-list spend
/// moves, per model, fitted over the trailing 14 days.
///
/// **One row per (account, window, local day fitted)**, never overwritten by
/// the next day's, so the history of rates is kept: the factor drifts by
/// about ±30% across model generations, and the allowance views (#227) read
/// how it moved. A refit on the same day replaces that day's row.
///
/// Written once a day by `SpendMeterFitWorker`; read by the live meter
/// (#318) and the allowance views (#219, #227, #277). A few rows per day.
///
/// **The intercept is never added between readings.** It is "usage not on
/// this Mac" — claude.ai, a phone, cloud routines — as points per observed
/// hour, averaged. Adding it to a live estimate would make the meter climb
/// while nothing is running; usage elsewhere arrives with the next real
/// reading instead. It is stored for the "other surfaces" view (#219), next
/// to the model-free measure it disagrees with (`noSpendRiseShare`).
///
/// All columns are plain values with defaults, so adding this table is a
/// lightweight migration.
@Model
public final class SpendMeterFit {
    #Index<SpendMeterFit>(
        [\.fitKey],
        [\.fittedDay],
        [\.accountId, \.window, \.fittedDay]
    )

    /// `"<accountId>|<window>|<fittedDay>"`. Composite because SwiftData can
    /// only enforce uniqueness on one attribute.
    @Attribute(.unique) public var fitKey: String

    /// `Account.id`.
    public var accountId: String
    /// `five_hour`, `seven_day`, or a scoped `limits[]` identity such as
    /// `weekly_scoped|Fable|` — the same key `WindowSpec.key` uses.
    public var window: String
    /// Local `yyyy-MM-dd` the fit was made for. The span ends at its start.
    public var fittedDay: String
    public var fittedAt: Date
    public var spanStart: Date
    public var spanEnd: Date

    /// `{"<model>": points per API dollar}` for every model with enough
    /// spend in the span to fit. JSON because the set of models is open and
    /// changes with every release. A model missing from it moves the meter
    /// at `pooledRate`. See `modelRates`.
    public var modelRatesJSON: String = "{}"
    /// Points per observed hour not explained by local spend. Never added
    /// between readings (see the type doc).
    public var interceptPerHour: Double = 0
    /// One factor for all models: Σ rise ÷ Σ spend. For a scoped window it
    /// spreads that cap's rise over every model's spend, so read the
    /// per-model rates there instead.
    public var pooledRate: Double = 0

    /// The per-model fit's error over its active hours.
    public var r2: Double = 0
    /// Points per hour.
    public var rmse: Double = 0
    /// `pooledRate`'s R² over the same hours.
    public var pooledR2: Double = 0

    /// Observed hours: the rows the fit used.
    public var hours: Int = 0
    /// Observed hours with any rise or any spend; the hours the error is
    /// scored over.
    public var activeHours: Int = 0
    public var totalSpendUSD: Double = 0
    public var totalRise: Double = 0
    /// Spend on models too small to fit (under 1% each), left out.
    public var unfittedSpendUSD: Double = 0

    /// The NNLS intercept's share of the rise: `interceptPerHour × hours ÷
    /// totalRise`.
    public var interceptShare: Double = 0
    /// The share of the rise in observed hours with no local spend: the
    /// model-free measure of usage off this Mac.
    public var noSpendRiseShare: Double = 0

    /// `SpendMeterFitter.method` at fit time, e.g. `nnls-hourly-v1`, so a
    /// later method can tell its rows from these.
    public var method: String = ""

    public static func makeKey(accountId: String, window: String, fittedDay: String) -> String {
        "\(accountId)|\(window)|\(fittedDay)"
    }

    public init(result: SpendMeterFitResult, fittedDay: String, fittedAt: Date) {
        self.fitKey = Self.makeKey(accountId: result.accountId, window: result.window, fittedDay: fittedDay)
        self.accountId = result.accountId
        self.window = result.window
        self.fittedDay = fittedDay
        self.fittedAt = fittedAt
        self.spanStart = result.spanStart
        self.spanEnd = result.spanEnd
        apply(result, fittedAt: fittedAt)
    }

    /// Overwrite every fitted value. Identity (account, window, day) stays.
    public func apply(_ result: SpendMeterFitResult, fittedAt: Date) {
        self.fittedAt = fittedAt
        spanStart = result.spanStart
        spanEnd = result.spanEnd
        modelRatesJSON = Self.encode(result.modelRates)
        interceptPerHour = result.interceptPerHour
        pooledRate = result.pooledRate
        r2 = result.r2
        rmse = result.rmse
        pooledR2 = result.pooledR2
        hours = result.hours
        activeHours = result.activeHours
        totalSpendUSD = result.totalSpendUSD
        totalRise = result.totalRise
        unfittedSpendUSD = result.unfittedSpendUSD
        interceptShare = result.interceptShare
        noSpendRiseShare = result.noSpendRiseShare
        method = result.method
    }

    /// `modelRatesJSON`, decoded. Empty when it does not parse.
    public var modelRates: [String: Double] {
        guard let data = modelRatesJSON.data(using: .utf8),
              let rates = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return rates
    }

    /// Sorted keys, so the same rates always store as the same text.
    static func encode(_ rates: [String: Double]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rates) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
