import Foundation

/// Tells a MetricKit CPU-exception report the forecast grader plausibly
/// caused from one that is a real regression (PACER-Z, PACER-C).
///
/// The grader uses one whole core when plugged in and idle (`full`), more
/// under Speed up (`multi`), by design, so macOS files an `MXCPUException`
/// ("90 s of CPU in about 120 s") for it every so often. Those reports are
/// worth keeping as a count, not as an email: the Sentry alert rules mail on
/// `level >= warning`.
///
/// Evidence reachable in `beforeSend`: the mechanism, the `arena.cpu_mode`
/// scope tag, and the exception value ("totalCPUTime:90 sec
/// totalSampledTime:144.765 sec"). Frames are NOT usable: sentry-cocoa builds
/// them from MetricKit's call-stack tree with only a binary name, an
/// instruction address and an image address (`SentryMetricKitIntegration.m`,
/// `convertMXFramesToSentryStacktrace`). Function and file names are added by
/// Sentry's server-side symbolication, so an "is this frame in the arena"
/// check cannot run on the device. The CPU rate stands in for it: a grader in
/// `full` mode is one thread, so a report averaging well over one core was not
/// the grader.
///
/// The tag is the mode at send time; MetricKit delivers a report some time
/// after the work, so it can be a mode behind. A miss here only means an email
/// that is sent today, which is the safe direction.
public enum MetricKitCPUClassifier {
    public static let mechanism = "mx_cpu_exception"
    /// The one group these reports share, so a hundred of them are one issue
    /// that is not "new" or "returning" each time a stack shifts.
    public static let fingerprint = ["metrickit-cpu", "arena"]

    public enum Decision: Equatable, Sendable {
        /// Leave the event's level and grouping as they are.
        case unchanged
        /// Level `info`, grouped under `fingerprint`.
        case demoteAsArena
    }

    /// CPU seconds over sampled seconds, from the exception value; nil when it
    /// does not say.
    public static func averageCores(exceptionValue: String?) -> Double? {
        guard let value = exceptionValue else { return nil }
        func seconds(after label: String) -> Double? {
            guard let range = value.range(of: label) else { return nil }
            let rest = value[range.upperBound...]
            let number = rest.prefix { $0.isNumber || $0 == "." }
            return Double(number)
        }
        guard let cpu = seconds(after: "totalCPUTime:"),
              let sampled = seconds(after: "totalSampledTime:"), sampled > 0 else { return nil }
        return cpu / sampled
    }

    /// - Parameters:
    ///   - mechanism: the first exception's mechanism type.
    ///   - mode: the `arena.cpu_mode` tag.
    ///   - exceptionValue: the first exception's value.
    ///   - cores: the Mac's active core count, the most `multi` can use.
    public static func decide(mechanism: String?, mode: String?, exceptionValue: String?,
                              cores: Int) -> Decision {
        guard mechanism == Self.mechanism, let mode,
              let average = averageCores(exceptionValue: exceptionValue) else { return .unchanged }
        // Slack over the exact limit: MetricKit's sampled window is approximate.
        switch mode {
        case "full": return average <= 1.25 ? .demoteAsArena : .unchanged
        case "multi": return average <= Double(max(1, cores)) ? .demoteAsArena : .unchanged
        default: return .unchanged
        }
    }
}
