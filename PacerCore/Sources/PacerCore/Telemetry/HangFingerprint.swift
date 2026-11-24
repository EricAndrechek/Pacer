import Foundation

/// Splits Sentry's "App Hanging" issue by cause when Pacer is not in the stack.
///
/// Sentry groups a hang by its in-app frames. When the main thread's only
/// Pacer frames are the entry point (`main`, `PacerApp.$main`), every hang
/// spent in system code got one issue, whatever the system was doing (PACER-M:
/// SwiftUI work in the display-cycle flush, HIToolbox's input-source file lock
/// and WindowServer round trips, #437). Those get
/// `["app-hang-system", trigger, trigger, image]`:
///
/// - **trigger**: the first two frames past the run loop, which say what the
///   run loop was running (`-[_NSMenuShortcutUpdater schedule:]`'s block,
///   `UC::DriverCore::continueProcessing` then `stepTransactionFlush`, a
///   WindowServer datagram). That end of the stack is the same in every
///   sample of one hang. The other end is wherever the CPU happened to be:
///   keyed on the three innermost frames, 2,275 logged hangs made 1,392
///   groups.
/// - **image**: the library of the innermost frame, past the runtime every
///   caller shares (libsystem, libdispatch, libxpc, libobjc, the Swift
///   runtime, dyld), so a wait is told apart by who waits: `mach_msg` from
///   QuartzCore's fence is not `mach_msg` from SkyLight.
///
/// Every PACER-M event (50, from 7 Macs) makes 20 groups this way.
///
/// The names are resolved on the Mac and sent as the fingerprint. In-process
/// frames carry only addresses (Sentry names them on its server), so `dladdr`
/// names the few the key needs: symbol names of code, never an image's path,
/// demangled so they read as code and pass `TelemetryScrubber` whole.
public enum HangFingerprint {
    public struct Frame: Sendable, Equatable {
        /// The name the frame already carries. In-process Sentry leaves it
        /// empty, so this is for tests and a symbolicated frame.
        public var function: String?
        /// The program counter for the innermost frame, the return address
        /// for every other (Sentry's `instructionAddress`).
        public var address: UInt?
        /// The binary's file name or path (Sentry's `package`).
        public var image: String?
        /// Sentry's own `inApp` mark (the image is Pacer's executable).
        public var inApp: Bool?

        public init(function: String? = nil, address: UInt? = nil, image: String? = nil, inApp: Bool? = nil) {
            self.function = function
            self.address = address
            self.image = image
            self.inApp = inApp
        }
    }

    public static let prefix = "app-hang-system"
    static let triggerCount = 2
    /// `main` and `PacerApp.$main`, with room for a thunk. A longer run of
    /// Pacer frames is Pacer code.
    static let entryLimit = 3
    /// How far past the entry point to look for the trigger. Run-loop frames
    /// take about 15; this bounds the names resolved for a stack with no
    /// trigger in it.
    static let triggerScan = 40
    static let nameLimit = 160

    /// - Parameters:
    ///   - frames: the main thread's stack as Sentry holds it, outermost
    ///     caller first (the frame that was running is last).
    ///   - symbolName: names an address (`dladdr`). Asked only about the
    ///     frames the key needs, outermost first, each once.
    /// - Returns: `nil` to keep Sentry's grouping: there is a Pacer frame
    ///   other than the entry point, or no Pacer frame at all (the stack was
    ///   cut off before `main`, so what called into the system is unknown).
    public static func fingerprint(frames: [Frame],
                                   symbolName: (UInt) -> String? = HangStackSummary.symbolName(at:)) -> [String]? {
        // Sentry's in-app marks rule out most hangs in Pacer's own code before
        // any frame is named: the entry point is one short run of Pacer
        // frames, so a longer run or a second one is Pacer code.
        let inApp = frames.indices.filter { isInApp(frames[$0]) }
        guard let first = inApp.first, let last = inApp.last,
              inApp.count <= entryLimit, last - first + 1 == inApp.count else { return nil }

        func name(_ index: Int) -> String? {
            if let known = frames[index].function, !known.isEmpty { return known }
            guard let address = frames[index].address, address > 0 else { return nil }
            // A return address is the instruction after the call, which is the
            // next function's first when the call was the caller's last
            // instruction. One byte back is always still in the caller.
            return symbolName(index == frames.count - 1 ? address : address - 1)
        }

        // The only names read before the decision, all in Pacer's own binary.
        for index in inApp where !isEntryPoint(name(index)) { return nil }

        var trigger: [String] = []
        var index = last + 1
        while index < frames.count, index <= last + triggerScan, trigger.count < triggerCount {
            defer { index += 1 }
            guard !isRuntime(frames[index].image), let raw = name(index), !isRunLoop(raw) else { continue }
            let shown = readable(raw)
            if trigger.last != shown { trigger.append(shown) }
        }
        let image = frames.reversed().lazy.compactMap { imageName($0.image) }.first { !isRuntime($0) }
        return [prefix] + (trigger.isEmpty ? ["unknown"] : trigger) + [image.map { family[$0] ?? $0 } ?? "unknown"]
    }

    static func isInApp(_ frame: Frame) -> Bool {
        if let inApp = frame.inApp { return inApp }
        return imageName(frame.image).map { $0.hasPrefix("Pacer") } ?? false
    }

    /// `main`, and `static <the @main type>.$main()` in module Pacer
    /// (`$s5Pacer0A3AppV5$mainyyFZ` for `PacerApp`). Exact shapes: Pacer's
    /// binary also holds stubs such as `objc_msgSend$mainBundle`.
    static func isEntryPoint(_ name: String?) -> Bool {
        guard let name else { return false }
        return name == "main" || (name.hasPrefix("$s5Pacer") && name.hasSuffix("5$mainyyFZ"))
    }

    /// The libraries under every caller: a frame in one says what is being
    /// done (a lock, a syscall, a retain, a dispatch), not who is doing it.
    /// A frame with no image is no better.
    static func isRuntime(_ image: String?) -> Bool {
        guard let file = imageName(image) else { return true }
        return file == "dyld" || runtimePrefixes.contains { file.hasPrefix($0) }
    }

    static let runtimePrefixes = ["libsystem_", "libdispatch", "libxpc", "libobjc", "libswift", "libc++", "libdyld"]

    /// One framework in several images. Which of them the sample caught the
    /// CPU in is noise.
    static let family = ["SwiftUICore": "SwiftUI", "AttributeGraph": "SwiftUI"]

    /// The run loop and event loop every main-thread stack starts with, and
    /// the trampolines that only hand a callback on: the frame after them is
    /// what the loop was running.
    static func isRunLoop(_ name: String) -> Bool {
        runLoopPrefixes.contains { name.hasPrefix($0) }
    }

    static let runLoopPrefixes = [
        "$s7SwiftUI3AppPAAE4main", "$s7SwiftUI6runApp",
        "NSApplicationMain", "-[NSApplication run]",
        "-[NSApplication(NSEventRouting) nextEventMatchingMask:",
        "-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:",
        "_DPSNextEvent", "_DPSBlockUntilNextEventMatchingListInMode",
        "_BlockUntilNextEventMatchingListInMode", "ReceiveNextEventCommon", "RunCurrentEventLoopInMode",
        "CFRunLoopRun", "_CFRunLoopRun", "__CFRunLoop", "__CFRUNLOOP_IS_", "__CFMachPortPerform",
        "__NSFireDelayedPerform", "__NSFireTimer", "__NSThreadPerformPerform",
    ]

    static func imageName(_ image: String?) -> String? {
        guard let image, !image.isEmpty else { return nil }
        let file = (image as NSString).lastPathComponent
        return file.isEmpty ? nil : file
    }

    /// A symbol as code reads: Swift names demangled, C++ names reduced to
    /// their qualified name, a block named after the function it is in,
    /// whitespace collapsed, capped. A mangled name, or a block's
    /// (`___LSScheduleNotificationFunction_block_invoke_2`), is a long run of
    /// letters, digits and underscores, which `TelemetryScrubber` takes for a
    /// token and redacts.
    static func readable(_ symbol: String) -> String {
        let (base, block) = splitBlock(symbol)
        var name = swiftDemangled(base) ?? cxxQualifiedName(base) ?? (block == nil ? base : blockOwner(base))
        if let block { name += block == 1 ? " block" : " block \(block)" }
        let flat = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > nameLimit ? String(flat.prefix(nameLimit)) : flat
    }

    /// `X_block_invoke` is the first block in X, `X_block_invoke_N` the Nth.
    static func splitBlock(_ symbol: String) -> (String, Int?) {
        guard let range = symbol.range(of: "_block_invoke", options: .backwards) else { return (symbol, nil) }
        let tail = symbol[range.upperBound...]
        let number: Int
        if tail.isEmpty {
            number = 1
        } else if tail.first == "_", let n = Int(tail.dropFirst()) {
            number = n
        } else {
            return (symbol, nil)
        }
        return (String(symbol[..<range.lowerBound]), number)
    }

    /// The function a C or Objective-C block is in: the compiler prefixes
    /// its name with `__`, and an Objective-C method's with `__<length>`
    /// (`__35-[_NSMenuShortcutUpdater schedule:]`).
    private static func blockOwner(_ base: String) -> String {
        guard base.hasPrefix("__") else { return base }
        let rest = base.dropFirst(2)
        let afterLength = rest.drop { $0.isASCII && $0.isNumber }
        if afterLength.count < rest.count, afterLength.hasPrefix("-[") || afterLength.hasPrefix("+[") {
            return String(afterLength)
        }
        return String(rest)
    }

    static func swiftDemangled(_ symbol: String) -> String? {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$S") else { return nil }
        let length = symbol.utf8.count
        return symbol.withCString { mangled -> String? in
            guard let out = swift_demangle(mangled, length, nil, nil, 0) else { return nil }
            defer { free(out) }
            return String(cString: out)
        }
    }

    /// `_ZN2CA11Transaction6commitEv` → `CA::Transaction::commit` (and a
    /// block's `___ZN…Ev`, the function the block is in). Reads the
    /// qualifiers up to the first part that is not a plain name (template
    /// arguments, an operator, a constructor) and drops the parameter types.
    /// Not a full demangler: libc++abi's is not linked into every binary that
    /// links PacerCore, and grouping needs only a stable, readable name.
    static func cxxQualifiedName(_ symbol: String) -> String? {
        var rest = Substring(symbol)
        while rest.hasPrefix("__") { rest = rest.dropFirst() }
        guard rest.hasPrefix("_Z") else { return nil }
        rest = rest.dropFirst(2)
        if rest.hasPrefix("L") { rest = rest.dropFirst() }  // internal linkage
        var parts: [Substring] = []
        if rest.hasPrefix("N") {
            rest = rest.dropFirst()
            while let c = rest.first, c == "K" || c == "V" || c == "r" { rest = rest.dropFirst() }
            while let part = sourceName(&rest) { parts.append(part) }
        } else if let part = sourceName(&rest) {
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }
        return parts.map { $0.hasPrefix("_GLOBAL__N") ? "(anonymous namespace)" : String($0) }
            .joined(separator: "::")
    }

    /// `<length><identifier>`, the Itanium C++ ABI's source name.
    private static func sourceName(_ rest: inout Substring) -> Substring? {
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let length = Int(digits), length > 0 else { return nil }
        let body = rest.dropFirst(digits.count)
        guard body.count >= length else { return nil }
        rest = body.dropFirst(length)
        return body.prefix(length)
    }
}

/// The Swift runtime's demangler, exported by libswiftCore, which every Swift
/// binary loads. `flags` must be 0; with no buffer it returns a string the
/// caller frees, or nil for a name that is not a Swift symbol.
@_silgen_name("swift_demangle")
private func swift_demangle(_ mangledName: UnsafePointer<CChar>, _ mangledNameLength: Int,
                            _ outputBuffer: UnsafeMutablePointer<CChar>?,
                            _ outputBufferSize: UnsafeMutablePointer<Int>?,
                            _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
