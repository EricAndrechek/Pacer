import Darwin
import Foundation

/// The top of the main thread's stack, as one local log line, for every hang
/// the watchdog reports (`HangReporter`).
///
/// Sentry's daily cap on hang events means most hangs leave no stack anywhere;
/// the log is local and uncapped, so a 20 s stall on a loaded Mac can still be
/// explained afterwards. Symbol and image names only: no paths, no arguments, no data.
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
            return frame.address.map { clip(locate($0)) } ?? "?"
        }
        return top.isEmpty ? nil : top.joined(separator: " < ")
    }

    /// An unnamed frame, named here: Sentry symbolicates on its server, so
    /// in-process its frames carry only an address, and a bare address in a
    /// log is useless later (the first install of this logged nothing but
    /// `0x1a3abf294 < …`). `dladdr` gives the image and the nearest exported
    /// symbol; the image's file name only, never its path. `image +0xoffset`
    /// when there is no symbol, the address itself when not even an image.
    static func locate(_ address: String) -> String {
        let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        guard let value = UInt(hex, radix: 16), let pointer = UnsafeRawPointer(bitPattern: value) else { return address }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0, let fname = info.dli_fname else { return address }
        let image = (String(cString: fname) as NSString).lastPathComponent
        if let sname = info.dli_sname {
            return "\(image) \(String(cString: sname))"
        }
        let base = UInt(bitPattern: info.dli_fbase)
        return value >= base ? "\(image) +0x\(String(value - base, radix: 16))" : "\(image) \(address)"
    }

    private static func clip(_ s: String) -> String {
        s.count > nameLimit ? String(s.prefix(nameLimit)) + "…" : s
    }
}
