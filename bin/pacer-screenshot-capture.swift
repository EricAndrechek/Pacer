// Captures the README window scenes for `make screenshots` — the real window
// the app ships, composited by the window server, not a drawing of one (#128).
//
//   swiftc -O -import-objc-header bin/screenshot-virtual-display.h \
//       bin/pacer-screenshot-capture.swift -o build/pacer-screenshot-capture
//   build/pacer-screenshot-capture <request-dir> [--virtual-display]
//
// The app (PACER_SCREENSHOT_MODE) puts each scene in a real window and drops
// `<name>.request` ({"windowID":…, "scale":…, "png":…}) in <request-dir>; this
// captures that window with ScreenCaptureKit, writes the PNG, and deletes the
// request. It runs until `stop` appears in <request-dir>.
//
// Why a separate process: capturing the screen needs the Screen Recording
// permission. Held by the terminal (or the CI runner), it never has to be
// granted to Pacer.app — a shipped app that can record the screen, for the
// sake of its README, is not a trade worth making.
//
// --virtual-display (CI): the runners' only display is 1×, and the README is
// 2×. A private-API virtual display (CGVirtualDisplay, the same one Chromium's
// test harness uses) gives a 1600×1200 pt display at 2×; its id is written to
// <request-dir>/display so the app can put its windows there. Never used on a
// person's Mac: a new display reshuffles every window they have open.
import AppKit
import ScreenCaptureKit

// A window-server connection. `SCScreenshotManager` needs one and a bare
// command-line process has none: without this it asserted
// (`CGS_REQUIRE_INIT`) on a normal window and hung forever on one beneath the
// wallpaper. `.prohibited`: this process never shows or activates anything.
NSApplication.shared.setActivationPolicy(.prohibited)

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: pacer-screenshot-capture <request-dir> [--virtual-display]\n".utf8))
    exit(64)
}
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
let wantsVirtualDisplay = args.contains("--virtual-display")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
func log(_ s: String) { print("[capture] \(s)"); fflush(stdout) }

var virtualDisplay: CGVirtualDisplay?
if wantsVirtualDisplay {
    guard ProcessInfo.processInfo.environment["CI"] == "true" else {
        log("refusing --virtual-display outside CI: adding a display rearranges a person's windows")
        exit(64)
    }
    let d = CGVirtualDisplayDescriptor()
    d.queue = DispatchQueue.main
    d.name = "Pacer screenshots"
    d.maxPixelsWide = 3200; d.maxPixelsHigh = 2400
    d.sizeInMillimeters = CGSize(width: 340, height: 255)
    d.serialNum = 1; d.productID = 0x1234; d.vendorID = 0x3456
    d.terminationHandler = { _, _ in }
    guard let display = CGVirtualDisplay(descriptor: d) else { log("virtual display: init failed"); exit(1) }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    settings.modes = [CGVirtualDisplayMode(width: 1600, height: 1200, refreshRate: 60)]
    guard display.apply(settings) else { log("virtual display: settings rejected"); exit(1) }
    virtualDisplay = display
    try? "\(display.displayID)".write(to: dir.appendingPathComponent("display"), atomically: true, encoding: .utf8)
    log("virtual display \(display.displayID): 1600×1200 pt @2×")
}

struct Request: Decodable { let windowID: UInt32; let scale: Double; let png: String }

func capture(_ request: Request) async throws {
    // The window list is fetched per request: the window did not exist when
    // this process started, and ScreenCaptureKit only captures what it lists.
    log("request: window \(request.windowID) @\(request.scale)×")
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    log("listed \(content.windows.count) windows")
    guard let window = content.windows.first(where: { $0.windowID == request.windowID }) else {
        throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "window \(request.windowID) not listed"])
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    // Sized from the filter, not the window frame: with the shadow included the
    // content is larger than the window, and a frame-sized capture squeezed it.
    let scale = max(Double(filter.pointPixelScale), request.scale)
    config.width = Int((filter.contentRect.width * scale).rounded())
    config.height = Int((filter.contentRect.height * scale).rounded())
    config.showsCursor = false
    config.captureResolution = .best
    // The window's real shadow, on a transparent margin — what a macOS window
    // screenshot looks like, and what the README's images have always had.
    config.ignoreShadowsSingleWindow = false
    log("capturing \(window.frame) level \(window.windowLayer) onScreen \(window.isOnScreen)")
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try png.write(to: URL(fileURLWithPath: request.png))
    log("✓ \(URL(fileURLWithPath: request.png).lastPathComponent) (\(image.width)×\(image.height))")
}

// Pay ScreenCaptureKit's slow first query up front, then say so: the app waits
// for `ready` before it opens any window.
_ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
try? "".write(to: dir.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
log("ready")

let deadline = Date().addingTimeInterval(900)
while Date() < deadline, !FileManager.default.fileExists(atPath: dir.appendingPathComponent("stop").path) {
    let requests = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    for url in requests where url.pathExtension == "request" {
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: url))
            try await capture(request)
        } catch {
            log("⚠️ \(url.lastPathComponent): \(error.localizedDescription)")
            try? "\(error.localizedDescription)".write(
                to: url.deletingPathExtension().appendingPathExtension("failed"), atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: url)
    }
    try? await Task.sleep(for: .milliseconds(100))
}
withExtendedLifetime(virtualDisplay) {}
log("done")
