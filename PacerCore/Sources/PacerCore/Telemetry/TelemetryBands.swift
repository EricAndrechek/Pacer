import Foundation

/// Coarse buckets for check-in values that would be too precise to send as
/// they are. A band answers "roughly how much" without identifying anyone:
/// the plan is to learn the shape of the install base (store sizes, disk
/// headroom, how hard people lean on a window), not individual numbers.
public enum TelemetryBands {

    /// Utilisation in 10-point bands: 0, 10, ... 100. Out-of-range input is
    /// clamped, so a server reading of 101 still lands in the top band.
    public static func percentBand(_ percent: Double) -> Int {
        guard percent.isFinite else { return 0 }
        let clamped = min(max(percent, 0), 100)
        return Int(clamped / 10) * 10
    }

    /// The smallest power of two at or above `value`, 0 for nothing.
    /// Sizes (MB of store, GB of free disk) read as 1, 2, 4, 8 ... so a
    /// dashboard groups them without a histogram.
    public static func powerOfTwoBucket(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        var bucket = 1
        while Double(bucket) < value, bucket < 1 << 40 { bucket <<= 1 }
        return bucket
    }

    public static func megabytesBucket(bytes: Int64) -> Int {
        powerOfTwoBucket(Double(bytes) / 1_048_576)
    }

    public static func gigabytesBucket(bytes: Int64) -> Int {
        powerOfTwoBucket(Double(bytes) / 1_073_741_824)
    }

    /// A count as its order of magnitude: 0 -> "0", 1...9 -> "e0",
    /// 10...99 -> "e1", 1M -> "e6". For token volumes, where the exact
    /// number would say too much and the magnitude is the signal.
    public static func magnitude(_ n: Int64) -> String {
        guard n > 0 else { return "0" }
        return "e\(Int(log10(Double(n))))"
    }

    /// A count in steps that stay readable: exact up to 10, then rounded up
    /// to 20, 50, 100, 200, 500, 1000 ... For file counts.
    public static func countBucket(_ n: Int) -> Int {
        guard n > 10 else { return max(n, 0) }
        for step in [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000] where n <= step {
            return step
        }
        return 200_000
    }

    /// A duration in milliseconds as a counter-key suffix ("lt100" ...
    /// "gt2000"), for things that happen far too often to report one by one
    /// but whose spread matters (the local API's snapshot build).
    public static func durationBucket(ms: Int) -> String {
        switch ms {
        case ..<100: return "lt100"
        case ..<250: return "100_250"
        case ..<500: return "250_500"
        case ..<1_000: return "500_1000"
        case ..<2_000: return "1000_2000"
        default: return "gt2000"
        }
    }

    /// At most `limit` values, evenly thinned and order-preserving, so a
    /// busy day's thousand runs of one command do not become a thousand
    /// metric points.
    public static func thinned<T>(_ values: [T], limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard values.count > limit else { return values }
        let stride = Double(values.count) / Double(limit)
        return (0..<limit).map { values[Int(Double($0) * stride)] }
    }
}
