import Foundation

/// What the app reports when the off-main store open fails (#380):
/// `PacerAppDelegate.prepareStoreOffMain` sends it through `Telemetry.problem`
/// before the alert that ends the app. Without it a migration that failed on a
/// user's Mac was seen by nobody: the `store.prepare` span goes only on success.
public enum StorePrepareTelemetry {

    /// The issue's message, fixed so every failure groups into one issue and
    /// the domain and code tell them apart.
    public static let failedMessage = "Store prepare failed"

    /// The error's domain and code, and its underlying error's when there is
    /// one (Core Data wraps SQLite's), the schema state found before the open,
    /// and how long it ran. Never the error's description or user info: those
    /// carry the store's path, which has the user's name in it.
    public static func failure(_ error: Error, before: StoreSchemaState,
                               elapsed: TimeInterval) -> Telemetry.Attributes {
        let ns = error as NSError
        var a: Telemetry.Attributes = [
            "error.domain": .string(TelemetryScrubber.scrub(ns.domain)),
            "error.code": .string(String(ns.code)),
            "store.before": .string(before.rawValue),
            "elapsed_ms": .int(Int((elapsed * 1000).rounded())),
        ]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            a["error.underlying_domain"] = .string(TelemetryScrubber.scrub(underlying.domain))
            a["error.underlying_code"] = .string(String(underlying.code))
        }
        return a
    }
}
