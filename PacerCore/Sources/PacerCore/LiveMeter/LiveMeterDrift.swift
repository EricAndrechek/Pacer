import Foundation
import SwiftData

/// One `[LiveMeter]` log line per window at each new reading: what the live
/// meter showed the moment before the reading landed, against the reading
/// (#318). So drift between the estimate and the server shows in
/// `make logs` without anything stored: the live value is never a reading.
///
/// Built from the previous reading and the turns between it and the new
/// one, exactly as the snapshot built it then (`LiveMeterSource`). Windows
/// with no fit say nothing, and neither does a window where the meter did
/// not move and the live value agreed with it.
public enum LiveMeterDrift {

    /// `readings` are the new poll's: window key and percent. Reads only, on
    /// its own context, so call it off the main actor after the poll's save.
    public static func log(container: ModelContainer, account: String, at: Date,
                           readings: [(key: String, percent: Double)]) {
        let context = ModelContext(container)
        let source = LiveMeterSource(context: context)
        let windows = readings.compactMap { source.latestReading(account: account, window: $0.key, before: at) }
        guard !windows.isEmpty else { return }
        let values = source.values(account: account, windows: windows, now: at)
        for (key, percent) in readings {
            guard let v = values[key] else { continue }
            // Only when there is something to compare: the meter moved, or
            // the live value disagreed with it. A busy account is read every
            // ~30 s, and a line for every poll that merely saw some spend was
            // hundreds an hour that each said "they agree".
            if !v.restarted, v.reading.percent == percent, v.percent == percent { continue }
            Log.write("LiveMeter", line(account: account, window: key, read: percent, live: v))
        }
    }

    /// `8c95 five_hour: read 42% · live showed 41% (38% 4m ago +3, $17.20 per-model) · -1`
    static func line(account: String, window: String, read: Double, live v: LiveMeterValue) -> String {
        let ago = Int(v.asOf.timeIntervalSince(v.reading.at).rounded())
        let from = v.restarted
            ? "0% after the reset"
            : "\(fmt(v.reading.percent))% \(ago >= 60 ? "\(ago / 60)m" : "\(ago)s") ago"
        return String(format: "%@ %@: read %@%% · live showed %@%% (%@ +%@, $%.2f %@) · %+.0f",
                      String(account.suffix(4)), window, fmt(read), fmt(v.percent),
                      from, fmt(v.addedPoints), v.spendUSD, v.rateSource.rawValue, v.percent - read)
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
