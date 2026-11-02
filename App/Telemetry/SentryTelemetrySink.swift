import Foundation
import PacerCore
@preconcurrency import Sentry

/// Where PacerCore's `Telemetry` calls go in the app: Sentry metrics,
/// after-the-fact transactions, breadcrumbs. Usage data only, so every call
/// checks the usage toggle first (breadcrumbs ride on crash reports, so they
/// check the crash toggle).
struct SentryTelemetrySink: Telemetry.Sink {

    /// Read by the `tracesSampler` in `TelemetryController`: a transaction we
    /// start says it is sampled, and nothing else ever is.
    static let sampleKey = "pacer.sample"

    func count(_ key: String, _ value: Int, attributes: Telemetry.Attributes) {
        guard TelemetryController.usageAllowed, value > 0 else { return }
        SentrySDK.metrics.count(key, value: UInt(value),
                                options: SentryMetricOptions(attributes: Self.attributes(attributes)))
    }

    func distribution(_ key: String, _ value: Double, unit: Telemetry.Unit, attributes: Telemetry.Attributes) {
        guard TelemetryController.usageAllowed, value.isFinite else { return }
        SentrySDK.metrics.distribution(key, value: value, options: Self.options(unit, attributes))
    }

    func gauge(_ key: String, _ value: Double, unit: Telemetry.Unit, attributes: Telemetry.Attributes) {
        guard TelemetryController.usageAllowed, value.isFinite else { return }
        SentrySDK.metrics.gauge(key, value: value, options: Self.options(unit, attributes))
    }

    /// A span measured elsewhere, sent as a transaction with its real start and
    /// end. sentry-cocoa keeps a timestamp set before `finish()`
    /// (`SentrySpanInternal.finishWithStatus` only fills a nil one).
    func span(_ span: Telemetry.Span) {
        guard TelemetryController.usageAllowed, span.end >= span.start else { return }
        let context = TransactionContext(name: span.name, operation: span.op)
        let transaction = SentrySDK.startTransaction(
            transactionContext: context, bindToScope: false,
            customSamplingContext: [Self.sampleKey: NSNumber(value: 1.0)])
        transaction.startTimestamp = span.start
        Self.setData(span.attributes, on: transaction)
        for child in span.children { Self.add(child, to: transaction) }
        transaction.timestamp = span.end
        transaction.finish()
    }

    func breadcrumb(_ category: String, _ message: String) {
        guard TelemetryController.crashAllowed else { return }
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.message = TelemetryScrubber.scrub(message)
        SentrySDK.addBreadcrumb(crumb)
    }

    // MARK: - Mapping

    private static func add(_ span: Telemetry.Span, to parent: Span) {
        let child = parent.startChild(operation: span.op, description: span.name)
        child.startTimestamp = span.start
        setData(span.attributes, on: child)
        for grandchild in span.children { add(grandchild, to: child) }
        child.timestamp = span.end
        child.finish()
    }

    private static func setData(_ attributes: Telemetry.Attributes, on span: Span) {
        for (key, value) in attributes {
            switch value {
            case .string(let s): span.setData(value: TelemetryScrubber.scrub(s), key: key)
            case .int(let i): span.setData(value: i, key: key)
            case .double(let d): if d.isFinite { span.setData(value: d, key: key) }
            case .bool(let b): span.setData(value: b, key: key)
            }
        }
    }

    private static func options(_ unit: Telemetry.Unit, _ attributes: Telemetry.Attributes) -> SentryMetricOptions {
        SentryMetricOptions(unit: Self.unit(unit), attributes: Self.attributes(attributes))
    }

    private static func attributes(_ attributes: Telemetry.Attributes) -> [String: SentryAttributeValue] {
        attributes.compactMapValues { value -> SentryAttributeValue? in
            switch value {
            case .string(let s): TelemetryScrubber.scrub(s)
            case .int(let i): i
            case .double(let d): d.isFinite ? d : nil
            case .bool(let b): b
            }
        }
    }

    private static func unit(_ unit: Telemetry.Unit) -> SentryUnit? {
        switch unit {
        case .millisecond: .millisecond
        case .second: .second
        case .byte: .byte
        case .percent: .percent
        case .none: nil
        }
    }
}
