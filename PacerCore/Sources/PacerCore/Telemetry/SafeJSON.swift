import Foundation

/// The only place allowed to serialize a JSON object (`SafeJSONLintTests`).
///
/// `JSONSerialization`'s writing entry point raises an Objective-C
/// `NSInvalidArgumentException` for NaN, ±Infinity, a non-JSON type (`Date`,
/// `URL`, …) and a top-level value that is not an array or dictionary. That is
/// not a Swift error, so `try?` does not catch it and the process dies. A
/// stall metric that divides by zero is enough to reach it.
/// `isValidJSONObject` checks all of those, so the check comes first and a bad
/// payload becomes `nil` for the caller to drop or log.
public enum SafeJSON {
    public static func data(_ object: Any, options: JSONSerialization.WritingOptions = []) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: options)
    }
}
