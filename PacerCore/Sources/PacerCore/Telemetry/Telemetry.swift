import Foundation
import Synchronization

/// The one door PacerCore code uses to report a measurement. PacerCore does not
/// link Sentry (the widget and the CLI link PacerCore, and neither may run the
/// SDK), so the app installs a sink at launch and everything else gets the
/// no-op default: tests, the widget, the CLI, every diagnostic launch mode.
///
/// Call sites stay one line and cheap: `Telemetry.distribution("scan.cycle_ms",
/// ms, attributes: ["phase": .string("scan")])`. Whether anything is sent, and
/// whether the user allowed it, is the sink's business, not the caller's.
///
/// **Rules for callers** (see AGENTS.md → Telemetry):
/// - attributes are our own names and enumerable values: a model id, a window
///   kind, a plan tier, a version. Never an account id, a project, a path, an
///   email, a cost, or free text;
/// - never call it per scan cycle, per click or per forecast: aggregate first,
///   or report only the slow ones.
public enum Telemetry {

    public enum Value: Sendable, Equatable {
        case string(String), int(Int), double(Double), bool(Bool)
    }

    public typealias Attributes = [String: Value]

    public enum Unit: String, Sendable { case millisecond, second, byte, percent, none }

    /// A finished span: something measured elsewhere and reported after the
    /// fact (a rebuild, a download, a slow scan cycle with its phases).
    public struct Span: Sendable, Equatable {
        public let op: String
        public let name: String
        public let start: Date
        public let end: Date
        public let attributes: Attributes
        public let children: [Span]

        public init(op: String, name: String, start: Date, end: Date,
                    attributes: Attributes = [:], children: [Span] = []) {
            self.op = op; self.name = name; self.start = start; self.end = end
            self.attributes = attributes; self.children = children
        }

        /// Children laid end to end from `start`, for phases measured as
        /// durations only (ScanCoordinator's `PhaseTimings`).
        public static func sequential(op: String, name: String, start: Date,
                                      phases: [(String, TimeInterval)],
                                      attributes: Attributes = [:]) -> Span {
            var cursor = start
            let children = phases.filter { $0.1 > 0 }.map { phase -> Span in
                let s = Span(op: "\(op).phase", name: phase.0, start: cursor,
                             end: cursor.addingTimeInterval(phase.1))
                cursor = s.end
                return s
            }
            return Span(op: op, name: name, start: start, end: cursor,
                        attributes: attributes, children: children)
        }
    }

    public protocol Sink: Sendable {
        func count(_ key: String, _ value: Int, attributes: Attributes)
        func distribution(_ key: String, _ value: Double, unit: Unit, attributes: Attributes)
        func gauge(_ key: String, _ value: Double, unit: Unit, attributes: Attributes)
        func span(_ span: Span)
        /// A line on the trail attached to the next crash: what the app was
        /// doing. Our own words only; scrubbed again by the sink.
        func breadcrumb(_ category: String, _ message: String)
    }

    struct NoSink: Sink {
        func count(_ key: String, _ value: Int, attributes: Attributes) {}
        func distribution(_ key: String, _ value: Double, unit: Unit, attributes: Attributes) {}
        func gauge(_ key: String, _ value: Double, unit: Unit, attributes: Attributes) {}
        func span(_ span: Span) {}
        func breadcrumb(_ category: String, _ message: String) {}
    }

    private static let installed = Mutex<any Sink>(NoSink())

    /// Called once by the app, after deciding telemetry may run at all.
    public static func install(_ sink: any Sink) { installed.withLock { $0 = sink } }

    static var sink: any Sink { installed.withLock { $0 } }

    public static func count(_ key: String, _ value: Int = 1, attributes: Attributes = [:]) {
        sink.count(key, value, attributes: attributes)
    }
    public static func distribution(_ key: String, _ value: Double, unit: Unit = .none,
                                    attributes: Attributes = [:]) {
        sink.distribution(key, value, unit: unit, attributes: attributes)
    }
    public static func gauge(_ key: String, _ value: Double, unit: Unit = .none,
                             attributes: Attributes = [:]) {
        sink.gauge(key, value, unit: unit, attributes: attributes)
    }
    public static func span(_ span: Span) { sink.span(span) }
    public static func breadcrumb(_ category: String, _ message: String) {
        sink.breadcrumb(category, message)
    }
}
