import Foundation

/// Splits Sentry's "App Hanging" issue by cause when Pacer is not in the stack.
///
/// Sentry groups a hang by its innermost in-app frame. When the main thread's
/// only Pacer frame is the entry point (`main`, `PacerApp.$main`), every hang
/// spent in system code lands in one issue whatever the system was doing
/// (PACER-M: SwiftUI text drawing and HIToolbox's input-source file lock were
/// one issue, #437). For those, the fingerprint is the innermost few system
/// frames. Nothing new is sent: the frame names are already in the event.
public enum HangFingerprint {
    public struct Frame: Sendable, Equatable {
        public var function: String?
        /// The binary's file name or path (Sentry's `package`).
        public var image: String?
        /// Sentry's own `inApp` mark, when the frame carries one.
        public var inApp: Bool?

        public init(function: String?, image: String? = nil, inApp: Bool? = nil) {
            self.function = function
            self.image = image
            self.inApp = inApp
        }
    }

    public static let prefix = "app-hang-system"
    static let signatureCount = 3
    static let nameLimit = 80

    /// - Parameter frames: the main thread's stack as Sentry holds it,
    ///   outermost caller first (the frame that was running is last), with
    ///   function names resolved where possible (frames with none are skipped:
    ///   an address is not stable across OS builds).
    /// - Returns: `nil` when a Pacer frame other than the entry point is
    ///   present (keep Sentry's grouping), else the fingerprint.
    public static func fingerprint(frames: [Frame]) -> [String]? {
        for frame in frames where isInApp(frame) && !isEntryPoint(frame.function) { return nil }
        var signatures: [String] = []
        for frame in frames.reversed() {
            guard let name = frame.function.map(normalise), !name.isEmpty, !isPlumbing(name), !isEntryPoint(name) else { continue }
            signatures.append(name)
            if signatures.count == signatureCount { break }
        }
        return [prefix] + (signatures.isEmpty ? ["unknown"] : signatures)
    }

    static func isInApp(_ frame: Frame) -> Bool {
        if let inApp = frame.inApp { return inApp }
        guard let image = frame.image else { return false }
        let file = (image as NSString).lastPathComponent
        return file == "Pacer" || file.hasPrefix("Pacer")
    }

    static func isEntryPoint(_ function: String?) -> Bool {
        guard let name = function.map(normalise) else { return false }
        return name == "main" || name.contains("$main") || name == "PacerApp.main"
    }

    /// Symbol name only: no addresses, offsets or argument lists.
    static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #" \+ \d+$"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "", options: .regularExpression)
        if let paren = s.firstIndex(of: "("), paren != s.startIndex, !s[paren...].hasPrefix("(anonymous") {
            s = String(s[..<paren])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > nameLimit ? String(s.prefix(nameLimit)) : s
    }

    /// Frames every hang shares: kernel waits and the run loop.
    static func isPlumbing(_ name: String) -> Bool {
        let prefixes = ["mach_msg", "__psynch_", "semaphore_wait", "kevent", "__ulock_wait",
                        "__CFRunLoop", "__CFRUNLOOP", "CFRunLoopRun", "_DPSNextEvent",
                        "NSApplicationMain", "RunCurrentEventLoopInMode", "ReceiveNextEventCommon",
                        "_BlockUntilNextEventMatchingListInMode", "-[NSApplication run]"]
        return prefixes.contains { name.hasPrefix($0) }
    }
}
