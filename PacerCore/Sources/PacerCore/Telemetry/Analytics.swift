import Foundation
import Synchronization

/// The one door PacerCore code (and the app's views) use to report a product
/// usage event: "the dashboard opened", "the History tab was viewed for 40 s",
/// "`pacer gate` ran". The app installs a PostHog sink at launch; everything
/// else gets the no-op default (tests, the widget, the CLI, every diagnostic
/// launch mode), so neither the widget nor the CLI links an analytics SDK.
///
/// This is the usage-data twin of `Telemetry` (which carries Sentry's crash
/// and performance signals). Events are built with the constructors on
/// `AnalyticsEvent` (`AnalyticsEvents.swift`), which take enums and coarse
/// numbers only; the sink then checks the "Usage data" toggle, the daily send
/// caps (`TelemetryBudget.takeAnalytics`) and scrubs every string
/// (`AnalyticsPayload`) before anything leaves.
///
/// **Rules for callers** (AGENTS.md → Telemetry):
/// - fire on a user action or once a day, never per scan cycle, per frame or
///   per forecast;
/// - properties are our own enumerable values or coarse numbers. Never an
///   account or org id, a project, a path, an email, a cost, an exact token
///   count, a prompt or an error description.
public enum Analytics {

    /// A property value. Lists and objects exist for the one event that needs
    /// them (`widget_inventory`: one entry per installed widget).
    public indirect enum Value: Sendable, Equatable {
        case string(String), int(Int), double(Double), bool(Bool)
        case list([Value])
        case object([String: Value])
    }

    public typealias Properties = [String: Value]

    public protocol Sink: Sendable {
        func capture(_ event: AnalyticsEvent)
    }

    struct NoSink: Sink {
        func capture(_ event: AnalyticsEvent) {}
    }

    private static let installed = Mutex<any Sink>(NoSink())

    /// Called once by the app, after deciding analytics may run at all.
    public static func install(_ sink: any Sink) { installed.withLock { $0 = sink } }

    static var sink: any Sink { installed.withLock { $0 } }

    public static func capture(_ event: AnalyticsEvent) { sink.capture(event) }
}

extension Telemetry.Value {
    /// The same value as an analytics property.
    public var analyticsValue: Analytics.Value {
        switch self {
        case .string(let s): .string(s)
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .bool(let b): .bool(b)
        }
    }
}
