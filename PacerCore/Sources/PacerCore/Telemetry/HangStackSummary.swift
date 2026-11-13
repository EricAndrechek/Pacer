import Foundation

/// The top of the main thread's stack, as one local log line, for every hang
/// the watchdog reports (`HangReporter`).
///
/// Sentry's daily cap on hang events means most hangs leave no stack anywhere;
/// the log is local and uncapped, so a 20 s stall on a loaded Mac can still be
/// explained afterwards. Symbol names only: no paths, no arguments, no data.
public enum HangStackSummary {
    public static let frameLimit = 12
    static let nameLimit = 90

    /// - Parameter frames: the stack as Sentry holds it, outermost caller first
    ///   (so the frame that was running is last). A frame the symbolicator
    ///   could not name falls back to its instruction address, which says
    ///   nothing about the user or their files.
    /// - Returns: `frame1 < frame2 < …`, innermost first, or `nil` for an
    ///   empty stack.
    public static func format(frames: [(function: String?, address: String?)],
                              limit: Int = frameLimit) -> String? {
        let top = frames.suffix(max(limit, 0)).reversed().map { frame -> String in
            if let name = frame.function?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return clip(name)
            }
            return frame.address.map { clip($0) } ?? "?"
        }
        return top.isEmpty ? nil : top.joined(separator: " < ")
    }

    private static func clip(_ s: String) -> String {
        s.count > nameLimit ? String(s.prefix(nameLimit)) + "…" : s
    }
}
