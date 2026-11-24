import Foundation

/// Splits Sentry's "App Hanging" issue by cause when Pacer is not in the stack.
///
/// Sentry groups a hang by its in-app frames. When the main thread's only
/// Pacer frames are the entry point (`main`, `PacerApp.$main`), every hang
/// spent in system code got one issue, whatever the system was doing (PACER-M:
/// SwiftUI layout in the display cycle, HIToolbox's input-source file lock,
/// WindowServer round trips, #437). Those get
/// `["app-hang-system", trigger, trigger]`, plus `waiting in <library>` when
/// the thread was waiting:
///
/// - **trigger**: the first two frames past the run loop and the display
///   cycle's own machinery, which say what the loop was running: the phase
///   (`__NSWindowGetDisplayCycleObserverForLayout` then
///   `-[NSWindow layoutIfNeeded]`, `CA::Layer::display_if_needed`, SwiftUI's
///   observer flush) or the event (`-[_NSMenuShortcutUpdater schedule:]`'s
///   block, a WindowServer datagram). That end of the stack is the same in
///   every sample of one hang. The other end is wherever the CPU happened to
///   be: keyed on the three innermost frames, 2,275 logged hangs made 1,392
///   groups. Inside a nested run loop (menu tracking, a modal) the trigger is
///   what the innermost loop runs.
/// - **waiting in**: only when the innermost frame is a system call (a
///   `mach_msg`, a lock, `fcntl`): the library that called it, past the
///   runtime every caller shares, so a wait is told apart by who waits.
///   A busy thread's innermost library is noise and is left out.
///
/// Every PACER-M event (50, from 7 Macs) makes 23 groups this way; the
/// display cycle's layout work is one (12 events) and SwiftUI's observer
/// flush another (8).
///
/// The names are resolved on the Mac and sent as the fingerprint. In-process
/// frames carry only addresses (Sentry names them on its server), so `dladdr`
/// names the few the key needs. Only frames in system libraries (`/System`,
/// `/usr/lib`) are named for it: code something else loaded into Pacer is
/// never named, and a wait in it is `waiting in non-system code`. Symbol
/// names and a library's file name, never a path, demangled so they read as
/// code and pass `TelemetryScrubber` whole.
public enum HangFingerprint {
    public struct Frame: Sendable, Equatable {
        /// The name the frame already carries. In-process Sentry leaves it
        /// empty, so this is for tests and a symbolicated frame.
        public var function: String?
        /// The program counter for the innermost frame, the return address
        /// for every other (Sentry's `instructionAddress`).
        public var address: UInt?
        /// The binary's path (Sentry's `package`).
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
    /// How far past a run-loop frame to look for the trigger. The display
    /// cycle's machinery takes about 10; this bounds the names resolved.
    static let triggerScan = 40
    static let nameLimit = 160

    /// - Parameters:
    ///   - frames: the main thread's stack as Sentry holds it, outermost
    ///     caller first (the frame that was running is last).
    ///   - symbolName: names an address (`dladdr`). Asked about each frame
    ///     at most once: the entry point's, then CoreFoundation's (to find
    ///     the run loop), then the system frames up to the trigger.
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

        var resolved: [Int: String?] = [:]
        func symbol(_ index: Int) -> String? {
            if let known = resolved[index] { return known }
            var name = frames[index].function.flatMap { $0.isEmpty ? nil : $0 }
            if name == nil, let address = frames[index].address, address > 0 {
                // A return address is the instruction after the call, which is
                // the next function's first when the call was the caller's last
                // instruction. One byte back is always still in the caller.
                name = symbolName(index == frames.count - 1 ? address : address - 1)
            }
            resolved[index] = name
            return name
        }

        // The only names read before the decision, all in Pacer's own binary.
        for index in inApp where !isEntryPoint(symbol(index)) { return nil }

        // A name the key may carry: system code only, and only a name that
        // survives a rebuild of that code.
        func keyName(_ index: Int) -> String? {
            let image = frames[index].image
            guard isSystem(image), !isRuntime(image), let raw = symbol(index) else { return nil }
            let name = withoutCloneSuffix(raw)
            return isUnstable(name) ? nil : name
        }

        func trigger(after start: Int) -> [String] {
            var found: [String] = []
            var index = start + 1
            while index < frames.count, index <= start + triggerScan, found.count < triggerCount {
                defer { index += 1 }
                guard let raw = keyName(index) else { continue }
                let shown = readable(raw)
                if isRunLoop(raw) || isDisplayCycle(shown) || found.last == shown { continue }
                found.append(shown)
            }
            return found
        }

        // Scan from the innermost run-loop frame that has work after it, so a
        // nested run loop (menu tracking, a modal) is keyed on what it runs,
        // and one that only waits on its port on what spun it. The run loop
        // is CoreFoundation's, so only its frames are named to find it.
        let anchors = frames.indices.dropFirst(last + 1).filter {
            imageName(frames[$0].image) == "CoreFoundation" && (keyName($0).map(isRunLoopAnchor) ?? false)
        }
        var key: [String] = []
        for start in anchors.reversed() + [last] {
            key = trigger(after: start)
            if !key.isEmpty { break }
        }
        key = [prefix] + (key.isEmpty ? ["unknown"] : key)

        // In a system call the thread is waiting, and who waits tells one wait
        // from another. Anywhere else the leaf is just where the sample caught
        // the CPU.
        if imageName(frames.last?.image) == "libsystem_kernel.dylib" {
            let waiter = frames.last { !isRuntime($0.image) }
            key.append("waiting in " + (waiter.map(waiterName) ?? "unknown"))
        }
        return key
    }

    private static func waiterName(_ frame: Frame) -> String {
        guard isSystem(frame.image), let file = imageName(frame.image) else { return "non-system code" }
        return family[file] ?? file
    }

    static func isInApp(_ frame: Frame) -> Bool {
        if let inApp = frame.inApp { return inApp }
        return imageName(frame.image).map { $0.hasPrefix("Pacer") } ?? false
    }

    /// `main`, and `static <the @main type>.$main()` in module Pacer
    /// (`$s5Pacer0A3AppV5$mainyyFZ` for `PacerApp`). A Release build inlines
    /// `$main` into `main`, so there the entry point is one frame; Sentry's
    /// server still shows two, the second from the dSYM's inlining record.
    /// Exact shapes: Pacer's binary also holds stubs such as
    /// `objc_msgSend$mainBundle`. Both names need the symbol table, which
    /// release.yml checks is there.
    static func isEntryPoint(_ name: String?) -> Bool {
        guard let name else { return false }
        return name == "main" || (name.hasPrefix("$s5Pacer") && name.hasSuffix("5$mainyyFZ"))
    }

    /// Apple's code: the OS's frameworks and libraries (the shared cache's
    /// images keep these install paths). Anything else in the process (Pacer,
    /// its frameworks, whatever got loaded into it) is never named.
    static func isSystem(_ image: String?) -> Bool {
        guard let image else { return false }
        return image.hasPrefix("/System/") || image.hasPrefix("/usr/lib/")
    }

    /// The libraries under every caller: a frame in one says what is being
    /// done (a lock, a syscall, a retain, a dispatch), not who is doing it.
    /// A frame with no image is no better.
    static func isRuntime(_ image: String?) -> Bool {
        guard let file = imageName(image) else { return true }
        return file == "dyld" || runtimePrefixes.contains { file.hasPrefix($0) }
    }

    static let runtimePrefixes = ["libsystem_", "libdispatch", "libxpc", "libobjc", "libswift", "libc++", "libdyld"]

    /// One framework in several images. Which of them the waiting call came
    /// from is not a different wait.
    static let family = ["SwiftUICore": "SwiftUI", "AttributeGraph": "SwiftUI"]

    /// Names a rebuild of the same code changes: compiler-made helpers and
    /// split-off cold paths, and the nearest-symbol stand-ins `dladdr` gives
    /// inside a stripped Swift framework (`__swift_memcpy72_8`). A frame with
    /// one is treated as unnamed.
    static func isUnstable(_ name: String) -> Bool {
        name.hasPrefix("__swift_") || name.hasPrefix("OUTLINED_FUNCTION_")
            || name.hasPrefix("get_enum_tag_for_layout_string")
            || name.contains("block_destroy_helper") || name.contains("block_copy_helper")
            || name.contains(".cold.") || name.hasSuffix(".cold")
    }

    /// `foo.12` → `foo`: the number the compiler gives a clone.
    static func withoutCloneSuffix(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        let tail = name[name.index(after: dot)...]
        return !tail.isEmpty && tail.allSatisfy({ $0.isASCII && $0.isNumber }) ? String(name[..<dot]) : name
    }

    /// Where a run loop hands a callback over (`__CFRunLoopRun`, its
    /// `__CFRunLoopDo…` steps and `__CFRUNLOOP_IS_CALLING_OUT…` callouts).
    /// Not CoreFoundation's other `__CFRunLoop…` functions: adding an observer
    /// is work, not the loop.
    static func isRunLoopAnchor(_ name: String) -> Bool {
        ["__CFRunLoopRun", "CFRunLoopRunSpecific", "CFRunLoopRunInMode", "_CFRunLoopRunSpecific",
         "__CFRunLoopDo", "__CFRUNLOOP_IS_", "__CFMachPortPerform"].contains { name.hasPrefix($0) }
    }

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

    /// The display cycle's own machinery, between the run loop and the phase
    /// it runs (update constraints, layout, display, commit): every
    /// display-cycle hang passes through it, so it says nothing about which.
    /// Matched on the readable name.
    static func isDisplayCycle(_ name: String) -> Bool {
        displayCyclePrefixes.contains { name.hasPrefix($0) }
    }

    static let displayCyclePrefixes = [
        "UC::DriverCore::", "stepTransactionFlush", "modeScheduling",
        "CA::Transaction::", "CA::Context::commit_transaction",
        "NSDisplayCycleFlush", "NSDisplayCycleObserverInvoke",
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
        var name = swiftDemangled(base).map(withoutCompilerPrefixes)
            ?? cxxQualifiedName(base) ?? (block == nil ? base : blockOwner(base))
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

    /// What the optimiser and the bridging layer put in front of a Swift name
    /// (`function signature specialization <Arg[0] = Dead> of`, `generic
    /// specialization <…> of`, `@objc`, `partial apply forwarder for`): a
    /// rebuild changes them, the function stays the same. The `@objc` thunk
    /// and the closure it calls then read alike, one frame for the key.
    static func withoutCompilerPrefixes(_ name: String) -> String {
        var rest = Substring(name)
        while true {
            if let plain = ["@objc ", "partial apply forwarder for ", "merged "].first(where: { rest.hasPrefix($0) }) {
                rest = rest.dropFirst(plain.count)
                continue
            }
            guard let marker = ["function signature specialization <", "generic specialization <"]
                .first(where: { rest.hasPrefix($0) }) else { break }
            // Past the bracketed arguments, which nest, to ` of `.
            var depth = 0
            var end: Substring.Index?
            var index = rest.index(rest.startIndex, offsetBy: marker.count - 1)  // the opening `<`
            var previous: Character = " "
            while index < rest.endIndex, end == nil {
                let c = rest[index]
                if c == "<" { depth += 1 }
                if c == ">", previous != "-" {  // not a function type's `->`
                    depth -= 1
                    if depth == 0 { end = index }
                }
                previous = c
                index = rest.index(after: index)
            }
            guard let end, rest[rest.index(after: end)...].hasPrefix(" of ") else { break }
            rest = rest[rest.index(end, offsetBy: 5)...]  // `>` and ` of `
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
