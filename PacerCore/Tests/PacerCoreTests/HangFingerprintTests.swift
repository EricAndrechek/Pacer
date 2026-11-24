import Darwin
import Foundation
import Testing
@testable import PacerCore

/// `HangFingerprint` against real stacks: `HangFixtures/app-hanging-main-threads.json`
/// holds the main thread of real Sentry "App Hanging" events, outermost frame
/// first, in the shape the app has at runtime: Sentry's in-app mark, the
/// image's path (file name only for anything not Apple's), and the mangled
/// symbol (null where there is none). Every PACER-M event is there (the issue
/// #437 splits), plus stacks with a Pacer frame and stacks with none.
@Suite struct HangFingerprintTests {
    typealias F = HangFingerprint.Frame

    static let appKit = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    static let coreFoundation = "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
    static let kernel = "/usr/lib/system/libsystem_kernel.dylib"
    static let coreText = "/System/Library/Frameworks/CoreText.framework/Versions/A/CoreText"

    struct Fixture: Decodable {
        struct Stack: Decodable {
            let issue: String
            /// `entry-only`, `pacer-frame` or `no-pacer-frame`, as an
            /// independent pass over the events classified them.
            let kind: String
            /// `[inApp, index into images, symbol]`.
            let frames: [[Value]]
        }
        enum Value: Decodable {
            case int(Int), string(String), null
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if c.decodeNil() { self = .null }
                else if let i = try? c.decode(Int.self) { self = .int(i) }
                else { self = .string(try c.decode(String.self)) }
            }
            var string: String? { if case .string(let s) = self { return s }; return nil }
            var int: Int? { if case .int(let i) = self { return i }; return nil }
        }
        let images: [String]
        let stacks: [Stack]
    }

    /// A stack the way `HangReporter` builds it: addresses only, resolved
    /// through `symbolName`. Each frame gets a fake address 16 apart, so an
    /// address or the byte before it maps back to its frame.
    struct Replay {
        var frames: [F]
        var names: [String?]
        var asked: [Int] = []

        init(_ stack: Fixture.Stack) {
            frames = stack.frames.enumerated().map { i, f in
                F(address: UInt(i + 1) * 16, image: f[1].int.map { HangFingerprintTests.fixture.images[$0] },
                  inApp: f[0].int == 1)
            }
            names = stack.frames.map { $0[2].string }
        }

        init(_ named: [(String, String?)], inApp: Set<Int> = [0]) {
            frames = named.enumerated().map { i, f in F(address: UInt(i + 1) * 16, image: f.0, inApp: inApp.contains(i)) }
            names = named.map(\.1)
        }

        func contains(_ name: String) -> Bool { names.contains(name) }

        mutating func fingerprint() -> [String]? {
            var asked: [Int] = []
            let names = self.names
            let result = HangFingerprint.fingerprint(frames: frames) { address in
                let index = Int((address + 15) / 16) - 1
                asked.append(index)
                return names.indices.contains(index) ? names[index] : nil
            }
            self.asked = asked
            return result
        }
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "app-hanging-main-threads", withExtension: "json",
                                    subdirectory: "HangFixtures")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    static func replays(_ kind: String) -> [Replay] { fixture.stacks.filter { $0.kind == kind }.map { Replay($0) } }

    static func groups(_ replays: [Replay]) -> [[String]: Int] {
        var groups: [[String]: Int] = [:]
        for var replay in replays { if let fp = replay.fingerprint() { groups[fp, default: 0] += 1 } }
        return groups
    }

    // MARK: - Real stacks

    @Test func everyEntryOnlyHangIsSplitIntoAFewGroups() {
        let replays = Self.replays("entry-only")
        #expect(replays.count == 50)
        for var replay in replays {
            let fp = replay.fingerprint()
            #expect(fp?.first == HangFingerprint.prefix)
            #expect((2...4).contains(fp?.count ?? 0), "\(fp ?? [])")
        }
        // One issue became a bounded handful: tens, not one per hang.
        let groups = Self.groups(replays)
        #expect(groups.values.reduce(0, +) == 50)
        #expect(groups.count >= 10 && groups.count <= 25, "\(groups.count) groups")
    }

    @Test func oneCauseIsOneGroup() {
        let replays = Self.replays("entry-only")
        // The display cycle's layout pass, wherever in it the CPU was caught.
        let layout = Self.groups(replays.filter { $0.contains("__NSWindowGetDisplayCycleObserverForLayout_block_invoke") })
        #expect(layout.count == 1 && layout.values.first == 12, "\(layout)")
        #expect(layout.keys.first?.dropFirst().first == "NSWindowGetDisplayCycleObserverForLayout block")
        // SwiftUI's run-loop observer flush, whether it was in Charts or SwiftUI.
        let flush = Self.groups(replays.filter { $0.contains("$sSo9NSRunLoopC7SwiftUIE14flushObserversyyFZTf4d_n") })
        #expect(flush.count == 1 && flush.values.first == 8, "\(flush)")
        let flushKey = flush.keys.first ?? []
        #expect(flushKey.contains { $0.contains("NSRunLoop.flushObservers") && !$0.hasPrefix("function signature") })
    }

    @Test func theMenuShortcutLockIsItsOwnGroup() {
        let replays = Self.replays("entry-only")
        let isMenu = { (r: Replay) in r.contains("UpdateKeyboardAwareShortcutsForCurrentInputSource") }
        let menu = Self.groups(replays.filter(isMenu))
        #expect(menu == [["app-hang-system", "-[_NSMenuShortcutUpdater schedule:] block",
                          "UpdateKeyboardAwareShortcutsForCurrentInputSource", "waiting in CarbonCore"]: 3])
        // Nothing else lands in it.
        #expect(Self.groups(replays.filter { !isMenu($0) }).keys.allSatisfy { menu[$0] == nil })
    }

    @Test func aWaitIsSplitByWhoWaits() {
        // Every stack stuck in a system call: the same few primitives, many callers.
        let waits = Self.replays("entry-only").filter { $0.frames.last?.image == Self.kernel }
        #expect(waits.count >= 10)
        let waiters = Set(Self.groups(waits).keys.compactMap(\.last))
        #expect(waiters.count >= 5, "\(waiters)")
        #expect(waiters.allSatisfy { $0.hasPrefix("waiting in ") && !$0.contains("libsystem") })
        // A busy thread carries no library: where the sample caught it is noise.
        let busy = Self.replays("entry-only").filter { $0.frames.last?.image != Self.kernel }
        #expect(Self.groups(busy).keys.allSatisfy { !($0.last ?? "").hasPrefix("waiting in ") })
    }

    @Test func pacerCodeKeepsSentryGroupingAndNamesOnlyPacerFrames() {
        let replays = Self.replays("pacer-frame")
        #expect(replays.count > 20)
        for var replay in replays {
            #expect(replay.fingerprint() == nil)
            // Decided from Sentry's marks: at most the entry point's few frames,
            // all in Pacer's binary, are ever named.
            #expect(replay.asked.count <= HangFingerprint.entryLimit, "\(replay.asked)")
            #expect(replay.asked.allSatisfy { replay.frames[$0].inApp == true })
        }
    }

    @Test func aStackCutOffBeforeMainKeepsSentryGrouping() {
        for var replay in Self.replays("no-pacer-frame") {
            #expect(replay.fingerprint() == nil)
            #expect(replay.asked.isEmpty)
        }
    }

    @Test func namesOnlyPacersEntryPointAndSystemFrames() {
        for var replay in Self.replays("entry-only") {
            _ = replay.fingerprint()
            #expect(Set(replay.asked).count == replay.asked.count, "a frame was named twice")
            for index in replay.asked {
                let frame = replay.frames[index]
                #expect(frame.inApp == true || (HangFingerprint.isSystem(frame.image) && !HangFingerprint.isRuntime(frame.image)),
                        "named \(frame.image ?? "no image")")
            }
            // CoreFoundation's frames (to find the run loop), then the trigger.
            let elsewhere = replay.asked.filter {
                replay.frames[$0].inApp != true && HangFingerprint.imageName(replay.frames[$0].image) != "CoreFoundation"
            }
            #expect(elsewhere.count <= 2 * HangFingerprint.triggerScan)
        }
    }

    @Test func codeLoadedFromOutsideTheSystemIsNeverNamed() {
        // Sparkle's update check: its frames are where the trigger would be.
        let sparkle = Self.replays("entry-only").filter { $0.frames.contains { $0.image == "Sparkle" } }
        #expect(!sparkle.isEmpty)
        for var replay in sparkle {
            let fp = replay.fingerprint() ?? []
            #expect(replay.asked.allSatisfy { replay.frames[$0].image != "Sparkle" })
            #expect(!fp.contains { $0.contains("SPU") || $0.contains("Sparkle") }, "\(fp)")
        }
        // A wait inside such code says so, and nothing more.
        var injected = Replay([("/Applications/Pacer.app/Contents/MacOS/Pacer", "main"),
                               (Self.coreFoundation, "__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__"),
                               (Self.appKit, "-[NSThing work]"),
                               ("/Library/Input Methods/Acme.app/Contents/MacOS/Acme", "AcmeSecretWait"),
                               (Self.kernel, "mach_msg2_trap")])
        let fp = injected.fingerprint()
        #expect(fp == ["app-hang-system", "-[NSThing work]", "waiting in non-system code"])
        #expect(!injected.asked.contains(3))
    }

    @Test func aBusyHangIgnoresItsLeafAndAWaitItsPrimitive() {
        for var replay in Self.replays("entry-only") {
            let before = replay.fingerprint()
            var moved = replay
            if replay.frames.last?.image == Self.kernel {
                // The same wait on another primitive.
                moved.names[moved.names.count - 1] = "__psynch_cvwait"
            } else {
                // The same busy hang sampled a moment later, in another library.
                moved.frames[moved.frames.count - 1].image = Self.coreText
                moved.names[moved.names.count - 1] = "_ZNK4TRun10DrawGlyphsEP9CGContext"
            }
            #expect(moved.fingerprint() == before)
        }
    }

    @Test func fingerprintsPassTheScrubberWhole() {
        for var replay in Self.replays("entry-only") {
            for part in replay.fingerprint() ?? [] {
                #expect(TelemetryScrubber.scrub(part, home: "/Users/someone") == part, "\(part)")
                #expect(!part.contains("/"), "\(part)")
            }
        }
    }

    // MARK: - Synthetic stacks

    @Test func aNestedRunLoopIsKeyedOnWhatItRuns() {
        let outer: [(String, String?)] = [
            ("/Applications/Pacer.app/Contents/MacOS/Pacer", "main"),
            (Self.appKit, "-[NSApplication run]"),
            (Self.coreFoundation, "__CFRunLoopRun"),
            (Self.coreFoundation, "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__"),
            (Self.appKit, "-[NSApplication(NSEvent) sendEvent:]"),
            (Self.appKit, "-[NSMenu _popUpMenu]"),
            (Self.coreFoundation, "CFRunLoopRunSpecific"),
            (Self.coreFoundation, "__CFRunLoopRun"),
        ]
        // Menu tracking runs a timer that does the work.
        var busy = Replay(outer + [(Self.coreFoundation, "__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__"),
                                   (Self.appKit, "-[NSMenuTracker refresh]"), (Self.appKit, "-[NSMenuItem layout]"),
                                   (Self.coreText, "CTLineDraw")])
        #expect(busy.fingerprint() == ["app-hang-system", "-[NSMenuTracker refresh]", "-[NSMenuItem layout]"])
        // Menu tracking idles on its port: what opened the menu is the trigger.
        var idle = Replay(outer + [(Self.coreFoundation, "__CFRunLoopServiceMachPort"), (Self.kernel, "mach_msg2_trap")])
        #expect(idle.fingerprint() == ["app-hang-system", "-[NSApplication(NSEvent) sendEvent:]",
                                       "-[NSMenu _popUpMenu]", "waiting in CoreFoundation"])
    }

    @Test func buildUnstableNamesAreTreatedAsUnnamed() {
        var replay = Replay([("/Applications/Pacer.app/Contents/MacOS/Pacer", "main"),
                             (Self.coreFoundation, "__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__"),
                             (Self.appKit, "__block_destroy_helper.12"), (Self.appKit, "OUTLINED_FUNCTION_3"),
                             (Self.appKit, "__swift_closure_destructor.340"), (Self.appKit, "TSMThing.cold.1"),
                             (Self.appKit, "UpdateThing.2"), (Self.appKit, "UpdateThing"), (Self.appKit, "DrawThing")])
        #expect(replay.fingerprint() == ["app-hang-system", "UpdateThing", "DrawThing"])
    }

    @Test func theDisplayCyclesMachineryIsSkipped() {
        var replay = Replay([("/Applications/Pacer.app/Contents/MacOS/Pacer", "main"),
                             (Self.coreFoundation, "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__"),
                             ("/System/Library/PrivateFrameworks/UpdateCycle.framework/Versions/A/UpdateCycle",
                              "_ZN2UC10DriverCore18continueProcessingEv"),
                             (Self.appKit, "stepTransactionFlush"),
                             ("/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore",
                              "_ZN2CA11Transaction6commitEv"),
                             ("/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore",
                              "___ZN2CA7Context18commit_transactionEPNS_11TransactionEdPd_block_invoke"),
                             (Self.appKit, "NSDisplayCycleFlush"),
                             (Self.appKit, "__NSWindowGetDisplayCycleObserverForLayout_block_invoke"),
                             (Self.appKit, "-[NSWindow(NSConstraintBasedLayoutInternal) layoutIfNeeded]"),
                             (Self.coreText, "CTLineDraw")])
        #expect(replay.fingerprint() == ["app-hang-system", "NSWindowGetDisplayCycleObserverForLayout block",
                                         "-[NSWindow(NSConstraintBasedLayoutInternal) layoutIfNeeded]"])
    }

    // MARK: - Pieces

    @Test func returnAddressesAreNamedOneByteBack() {
        let frames = [F(address: 0x100, image: "/Applications/Pacer.app/Contents/MacOS/Pacer", inApp: true),
                      F(address: 0x200, image: Self.appKit, inApp: false),
                      F(address: 0x300, image: Self.appKit, inApp: false)]
        var asked: [UInt] = []
        _ = HangFingerprint.fingerprint(frames: frames) { address in
            asked.append(address)
            return address < 0x1ff ? "main" : "-[NSThing work]"
        }
        #expect(asked == [0xff, 0x1ff, 0x300])
    }

    @Test func dladdrNamesARealAddress() throws {
        // A C function in the shared cache, as a frame inside it would be.
        let getpid = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "getpid"))  // RTLD_DEFAULT
        let address = UInt(bitPattern: getpid)
        // `getpid` or an alias at the same address (`__getpid`).
        let name = try #require(HangStackSummary.symbolName(at: address))
        #expect(name.hasSuffix("getpid"), "\(name)")
        #expect(HangStackSummary.symbolName(at: address + 2) == name)
        #expect(HangStackSummary.symbolName(at: 0) == nil)
        #expect(HangStackSummary.address("0x\(String(address, radix: 16))") == address)

        // A Swift function in this binary, which is not stripped, as Pacer's
        // releases are not: mangled from dladdr, read as code.
        let closure: @convention(c) () -> Int32 = { 7 }
        let swiftAddress = UInt(bitPattern: unsafeBitCast(closure, to: Int.self))
        let mangled = try #require(HangStackSummary.symbolName(at: swiftAddress))
        #expect(mangled.hasPrefix("$s"), "\(mangled)")
        #expect(HangFingerprint.readable(mangled).contains("closure"), "\(HangFingerprint.readable(mangled))")
    }

    @Test func entryPointIsExact() {
        #expect(HangFingerprint.isEntryPoint("main"))
        #expect(HangFingerprint.isEntryPoint("$s5Pacer0A3AppV5$mainyyFZ"))
        #expect(!HangFingerprint.isEntryPoint("objc_msgSend$mainBundle"))
        #expect(!HangFingerprint.isEntryPoint("$s7SwiftUI3AppPAAE4mainyyFZ"))
        #expect(!HangFingerprint.isEntryPoint("$s9PacerCore15TelemetryBudgetC5flushyyF"))
        #expect(!HangFingerprint.isEntryPoint(nil))
    }

    @Test func symbolsReadAsCode() {
        #expect(HangFingerprint.readable("_ZN2CA11Transaction6commitEv") == "CA::Transaction::commit")
        #expect(HangFingerprint.readable("_ZN2UC10DriverCore18continueProcessingEv") == "UC::DriverCore::continueProcessing")
        #expect(HangFingerprint.readable("___ZN21CGSDatagramReadStream15mainQueueWakeupEv_block_invoke")
                == "CGSDatagramReadStream::mainQueueWakeup block")
        #expect(HangFingerprint.readable("___ZN2CA5Layer8display_Ev_block_invoke_3") == "CA::Layer::display_ block 3")
        #expect(HangFingerprint.readable("_ZNK12_GLOBAL__N_17CalloutclE19CGSNotificationTypePvm")
                == "(anonymous namespace)::Callout")
        #expect(HangFingerprint.readable("_ZL27CABackingStoreReleaseImagesP14CABackingStore") == "CABackingStoreReleaseImages")
        #expect(HangFingerprint.readable("__35-[_NSMenuShortcutUpdater schedule:]_block_invoke")
                == "-[_NSMenuShortcutUpdater schedule:] block")
        #expect(HangFingerprint.readable("___LSScheduleNotificationFunction_block_invoke_2")
                == "_LSScheduleNotificationFunction block 2")
        #expect(HangFingerprint.readable("__NSWindowGetDisplayCycleObserverForUpdateConstraints_block_invoke")
                == "NSWindowGetDisplayCycleObserverForUpdateConstraints block")
        #expect(HangFingerprint.readable("$s7SwiftUI13NSHostingViewC16beginTransactionyyF")
                == "SwiftUI.NSHostingView.beginTransaction() -> ()")
        #expect(HangFingerprint.readable("-[NSStatusItem _updateReplicants]") == "-[NSStatusItem _updateReplicants]")
        #expect(HangFingerprint.readable(String(repeating: "a", count: 300)).count == HangFingerprint.nameLimit)
    }

    @Test func compilerPrefixesAreDropped() {
        #expect(HangFingerprint.readable("$sSo9NSRunLoopC7SwiftUIE14flushObserversyyFZTf4d_n")
                .hasPrefix("static (extension in SwiftUI):"))
        let thunk = HangFingerprint.readable("$sSo9NSRunLoopC7SwiftUIE11addObserveryyyycFZySo05CFRunbF3RefaSg_So0gB8ActivityVSvSgtcfU_To")
        let body = HangFingerprint.readable("$sSo9NSRunLoopC7SwiftUIE11addObserveryyyycFZySo05CFRunbF3RefaSg_So0gB8ActivityVSvSgtcfU_")
        #expect(thunk == body && thunk.hasPrefix("closure #1"), "\(thunk)")
        #expect(HangFingerprint.withoutCompilerPrefixes("generic specialization <(Swift.Int) -> (), Swift.Array<A>> of Foo.bar() -> ()")
                == "Foo.bar() -> ()")
        #expect(HangFingerprint.withoutCompilerPrefixes("generic specialization <Unbalanced of Foo") == "generic specialization <Unbalanced of Foo")
        #expect(HangFingerprint.withoutCloneSuffix("foo.12") == "foo")
        #expect(HangFingerprint.withoutCloneSuffix("-[NSView displayIfNeeded]") == "-[NSView displayIfNeeded]")
        #expect(HangFingerprint.withoutCloneSuffix("Swift.Array.count") == "Swift.Array.count")
    }

    @Test func imagesAreSortedIntoSystemRuntimeAndTheRest() {
        for image in [Self.kernel, "/usr/lib/system/libdispatch.dylib", "/usr/lib/system/libxpc.dylib",
                      "/usr/lib/libobjc.A.dylib", "/usr/lib/swift/libswiftCore.dylib", "/usr/lib/dyld", nil] {
            #expect(HangFingerprint.isRuntime(image), "\(image ?? "nil")")
        }
        #expect(!HangFingerprint.isRuntime(Self.appKit))
        #expect(HangFingerprint.isSystem(Self.appKit) && HangFingerprint.isSystem("/usr/lib/libsqlite3.dylib"))
        for image in ["/Applications/Pacer.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
                      "/Users/someone/Applications/Pacer.app/Contents/MacOS/Pacer", "AppKit", nil,
                      "/System/Volumes/Data/Users/someone/Library/Injected.dylib",
                      "/usr/lib/../../Users/someone/Injected.dylib", "/usr/local/lib/libfoo.dylib"] {
            #expect(!HangFingerprint.isSystem(image), "\(image ?? "nil")")
        }
    }
}
