import Testing
@testable import PacerCore

@Suite struct HangFingerprintTests {
    typealias F = HangFingerprint.Frame

    private func stack(_ names: [String], image: String = "libsystem.dylib") -> [F] {
        names.map { F(function: $0, image: image) }
    }

    // Outermost first, as Sentry holds them.
    private func coreText(_ suffix: String = "") -> [F] {
        [F(function: "main", image: "Pacer"), F(function: "PacerApp.$main" + suffix, image: "Pacer")]
            + stack(["CA::Layer::display_if_needed\(suffix)", "ResolvedStyledText.StringDrawing.draw\(suffix)",
                     "TRun::DrawGlyphs(CGContext*)\(suffix)", "__CF_IS_OBJC\(suffix)"])
    }

    private func inputSource(_ suffix: String = "") -> [F] {
        [F(function: "main", image: "Pacer"), F(function: "PacerApp.$main", image: "Pacer")]
            + stack(["NSApplicationMain", "__CFRunLoopRun", "__CFRunLoopDoBlocks",
                     "__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__", "_NSMenuShortcutUpdater",
                     "InitializeInputSourceCache", "CCFFetchComponentData", "OpenCCFFile",
                     "SetCCFFileLock\(suffix)", "fcntl\(suffix)", "__fcntl\(suffix)"])
    }

    @Test func coreTextStack() {
        #expect(HangFingerprint.fingerprint(frames: coreText())
                == ["app-hang-system", "__CF_IS_OBJC", "TRun::DrawGlyphs", "ResolvedStyledText.StringDrawing.draw"])
    }

    @Test func inputSourceStack() {
        #expect(HangFingerprint.fingerprint(frames: inputSource())
                == ["app-hang-system", "__fcntl", "fcntl", "SetCCFFileLock"])
    }

    @Test func differentCausesDiffer() {
        #expect(HangFingerprint.fingerprint(frames: coreText()) != HangFingerprint.fingerprint(frames: inputSource()))
    }

    @Test func stableAcrossOffsetsAndAddresses() {
        #expect(HangFingerprint.fingerprint(frames: inputSource()) == HangFingerprint.fingerprint(frames: inputSource(" + 123")))
        #expect(HangFingerprint.fingerprint(frames: inputSource()) == HangFingerprint.fingerprint(frames: inputSource(" 0x1a2b3c")))
        #expect(HangFingerprint.fingerprint(frames: coreText()) == HangFingerprint.fingerprint(frames: coreText(" + 9")))
    }

    @Test func pacerFrameKeepsDefaultGrouping() {
        let frames = [F(function: "main", image: "Pacer"), F(function: "PaceChartView.body", image: "Pacer")]
            + stack(["__CF_IS_OBJC"])
        #expect(HangFingerprint.fingerprint(frames: frames) == nil)
        #expect(HangFingerprint.fingerprint(frames: [F(function: "x", image: "y", inApp: true)]) == nil)
    }

    @Test func allPlumbingFallsBack() {
        let frames = [F(function: "main", image: "Pacer")]
            + stack(["NSApplicationMain", "__CFRunLoopRun", "mach_msg2_trap", "mach_msg", "__psynch_cvwait",
                     "-[NSApplication run]", "_DPSNextEvent"])
        #expect(HangFingerprint.fingerprint(frames: frames) == ["app-hang-system", "unknown"])
        #expect(HangFingerprint.fingerprint(frames: []) == ["app-hang-system", "unknown"])
    }

    @Test func namesAreCapped() {
        let long = String(repeating: "a", count: 200)
        #expect(HangFingerprint.fingerprint(frames: stack([long]))?[1].count == 80)
    }
}
