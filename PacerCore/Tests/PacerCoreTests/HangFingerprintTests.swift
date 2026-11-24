import Darwin
import Foundation
import Testing
@testable import PacerCore

/// `HangFingerprint` against real stacks: `HangFixtures/app-hanging-main-threads.json`
/// holds the main thread of real Sentry "App Hanging" events, outermost frame
/// first, as the app has them at runtime: Sentry's in-app mark, the image, and
/// the symbol as `dladdr` names it (mangled; null where it names nothing).
/// Every PACER-M event is there (the issue #437 splits), plus stacks with a
/// Pacer frame and stacks with none.
@Suite struct HangFingerprintTests {
    typealias F = HangFingerprint.Frame

    struct Fixture: Decodable {
        struct Stack: Decodable {
            let issue: String
            /// `entry-only`, `pacer-frame` or `no-pacer-frame`, as an
            /// independent pass over the events classified them.
            let kind: String
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
        let stacks: [Stack]
    }

    /// A stack the way `HangReporter` builds it: addresses only, resolved
    /// through `symbolName`. Each frame gets a fake address 16 apart, so an
    /// address or the byte before it maps back to its frame.
    struct Replay {
        let frames: [F]
        let names: [String?]
        var asked: [Int] = []

        init(_ stack: Fixture.Stack) {
            frames = stack.frames.enumerated().map { i, f in
                F(address: UInt(i + 1) * 16, image: f[1].string, inApp: f[0].int == 1)
            }
            names = stack.frames.map { $0[2].string }
        }

        mutating func fingerprint() -> [String]? {
            var asked: [Int] = []
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

    static func stacks(_ kind: String) -> [Fixture.Stack] { fixture.stacks.filter { $0.kind == kind } }

    // MARK: - Real stacks

    @Test func everyEntryOnlyHangIsSplitIntoAFewGroups() {
        let stacks = Self.stacks("entry-only")
        #expect(stacks.count == 50)
        var groups: [[String]: Int] = [:]
        for stack in stacks {
            var replay = Replay(stack)
            guard let fp = replay.fingerprint() else {
                Issue.record("no fingerprint for a \(stack.issue) stack")
                continue
            }
            #expect(fp.first == HangFingerprint.prefix)
            #expect(fp.count == 4)
            groups[fp, default: 0] += 1
        }
        // One issue became a bounded handful: tens, not one per hang.
        #expect(groups.count >= 10 && groups.count <= 25, "\(groups.count) groups")
    }

    @Test func pacerCodeKeepsSentryGroupingAndNamesOnlyPacerFrames() {
        let stacks = Self.stacks("pacer-frame")
        #expect(stacks.count > 20)
        for stack in stacks {
            var replay = Replay(stack)
            #expect(replay.fingerprint() == nil, "\(stack.issue)")
            // Decided from Sentry's marks: at most the entry point's few frames,
            // all in Pacer's binary, are ever named.
            #expect(replay.asked.count <= HangFingerprint.entryLimit, "\(stack.issue): \(replay.asked)")
            #expect(replay.asked.allSatisfy { replay.frames[$0].inApp == true }, "\(stack.issue)")
        }
    }

    @Test func aStackCutOffBeforeMainKeepsSentryGrouping() {
        for stack in Self.stacks("no-pacer-frame") {
            var replay = Replay(stack)
            #expect(replay.fingerprint() == nil)
            #expect(replay.asked.isEmpty)
        }
    }

    @Test func namesOnlyTheFramesTheKeyNeeds() {
        for stack in Self.stacks("entry-only") {
            var replay = Replay(stack)
            _ = replay.fingerprint()
            // Outermost first, each once, and nowhere near the leaf.
            #expect(replay.asked == replay.asked.sorted() && Set(replay.asked).count == replay.asked.count)
            #expect(replay.asked.count <= HangFingerprint.entryLimit + HangFingerprint.triggerScan)
            #expect(!replay.asked.contains(replay.frames.count - 1), "\(stack.issue): the leaf was named")
        }
    }

    @Test func theMenuShortcutLockIsItsOwnGroup() {
        let all = Self.stacks("entry-only").map { stack -> ([String]?, Bool) in
            var replay = Replay(stack)
            return (replay.fingerprint(), replay.names.contains("UpdateKeyboardAwareShortcutsForCurrentInputSource"))
        }
        let menu = Set(all.filter(\.1).compactMap(\.0))
        #expect(all.filter(\.1).count == 3)
        #expect(menu == [["app-hang-system", "-[_NSMenuShortcutUpdater schedule:] block",
                          "UpdateKeyboardAwareShortcutsForCurrentInputSource", "CarbonCore"]])
        // Nothing else lands in it: not the SwiftUI work in the display cycle,
        // not the WindowServer round trips.
        #expect(all.filter { !$0.1 }.allSatisfy { !menu.contains($0.0 ?? []) })
    }

    @Test func aWaitIsSplitByWhoWaits() {
        // Every stack whose leaf is the mach_msg trap: the same wait, many callers.
        let waits = Self.stacks("entry-only").filter { $0.frames.last?[2].string == "mach_msg2_trap" }
        #expect(waits.count >= 5)
        let images = Set(waits.compactMap { stack -> String? in
            var replay = Replay(stack)
            return replay.fingerprint()?.last
        })
        #expect(images.count >= 3, "\(images)")
        #expect(!images.contains("libsystem_kernel.dylib"))
    }

    @Test func whereTheSampleCaughtTheCPUDoesNotMatter() {
        // The same hang sampled a moment later has a different leaf.
        for stack in Self.stacks("entry-only") {
            var replay = Replay(stack)
            var moved = Replay(frames: replay.frames, names: replay.names.dropLast() + ["somewhere_else"])
            #expect(replay.fingerprint() == moved.fingerprint())
        }
    }

    @Test func fingerprintsPassTheScrubberWhole() {
        for stack in Self.stacks("entry-only") {
            var replay = Replay(stack)
            for part in replay.fingerprint() ?? [] {
                #expect(TelemetryScrubber.scrub(part, home: "/Users/someone") == part, "\(part)")
                #expect(!part.contains("/"), "\(part)")
            }
        }
    }

    // MARK: - Pieces

    @Test func returnAddressesAreNamedOneByteBack() {
        let frames = [F(address: 0x100, image: "Pacer", inApp: true),
                      F(address: 0x200, image: "AppKit", inApp: false),
                      F(address: 0x300, image: "AppKit", inApp: false)]
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

        // A Swift function in this binary: mangled from dladdr, read as code.
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

    @Test func runtimeImagesAreSkipped() {
        for image in ["/usr/lib/system/libsystem_kernel.dylib", "libdispatch.dylib", "libxpc.dylib",
                      "libobjc.A.dylib", "libswiftCore.dylib", "libswift_Concurrency.dylib", "dyld", nil] {
            #expect(HangFingerprint.isRuntime(image), "\(image ?? "nil")")
        }
        for image in ["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "SkyLight", "libsqlite3.dylib"] {
            #expect(!HangFingerprint.isRuntime(image), "\(image)")
        }
    }
}

extension HangFingerprintTests.Replay {
    init(frames: [HangFingerprint.Frame], names: [String?]) {
        self.frames = frames
        self.names = names
    }
}
