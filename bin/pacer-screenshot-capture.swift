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
    // The main display, so the menu bar the menu-bar scenes photograph is this
    // 2× one; then a real macOS wallpaper, or the bar sits on a black desktop.
    // EXPERIMENT: the runner's display mirrors the 2x one, which makes the
    // 2x one main without moving origins (moving them flipped the text of
    // Pacer's SwiftUI status-item label).
    do {
        var config: CGDisplayConfigRef?
        let previousMain = CGMainDisplayID()
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayMirrorOfDisplay(config, previousMain, display.displayID)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        log("mirror \(previousMain) of \(display.displayID): \(err.rawValue); main now \(CGMainDisplayID())")
    }
    try? await Task.sleep(for: .seconds(1))
    let pictures = "/System/Library/Desktop Pictures"
    if let picture = ((try? FileManager.default.contentsOfDirectory(atPath: pictures)) ?? [])
        .sorted().first(where: { $0.hasSuffix(".heic") || $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }),
       let screen = NSScreen.screens.first(where: {
           ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }) {
        try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: "\(pictures)/\(picture)"), for: screen, options: [:])
        log("wallpaper: \(picture)")
    }
    try? await Task.sleep(for: .seconds(2))   // the wallpaper paints asynchronously
    try? "\(display.displayID)".write(to: dir.appendingPathComponent("display"), atomically: true, encoding: .utf8)
    log("virtual display \(display.displayID): 1600×1200 pt @2×, main")
}

struct Request: Decodable {
    /// "window" (default), "menubar", or "appearance".
    var kind: String?
    var windowID: UInt32?
    var scale: Double?
    var png: String?
    var rect: [Double]?
    var dark: Bool?
    var done: String?
}

func fail(_ s: String) -> NSError { NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

func handle(_ request: Request) async throws {
    switch request.kind ?? "window" {
    case "window": try await capture(request)
    case "menubar": try await captureMenuBar(request)
    case "appearance": try setDarkMode(request.dark ?? false)
    default: throw fail("unknown request kind \(request.kind ?? "-")")
    }
    if let done = request.done { FileManager.default.createFile(atPath: done, contents: nil) }
}

/// The system appearance, which is what the menu bar follows. CI only — on a
/// person's Mac this would change their whole system.
func setDarkMode(_ dark: Bool) throws {
    guard ProcessInfo.processInfo.environment["CI"] == "true" else { throw fail("appearance: CI only") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"]
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw fail("osascript exited \(p.terminationStatus)") }
    Thread.sleep(forTimeInterval: 2)   // let the menu bar and apps redraw
    log("system appearance: \(dark ? "dark" : "light")")
}

/// The menu bar with Pacer's menu open: everything on the display inside the
/// rectangle the app sends (top-left points) — the real bar, the neighbouring
/// status items, the wallpaper beneath. CI only.
func captureMenuBar(_ request: Request) async throws {
    guard ProcessInfo.processInfo.environment["CI"] == "true" else { throw fail("menubar: CI only") }
    guard let r = request.rect, r.count == 4, let png = request.png else { throw fail("menubar: rect and png required") }
    let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    // The menu opens just after the request is written; let it finish animating.
    try await Task.sleep(for: .milliseconds(1200))
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
        throw fail("menubar: no display holds \(rect)")
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    let scale = Double(filter.pointPixelScale)
    config.width = Int(rect.width * scale); config.height = Int(rect.height * scale)
    config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw fail("menubar: PNG encoding failed")
    }
    try data.write(to: URL(fileURLWithPath: png))
    log("✓ \(URL(fileURLWithPath: png).lastPathComponent) (\(image.width)×\(image.height), menu bar)")
}

func capture(_ request: Request) async throws {
    guard let windowID = request.windowID, let requestedScale = request.scale, let pngPath = request.png else {
        throw fail("window: windowID, scale and png required")
    }
    let request = (windowID: windowID, scale: requestedScale, png: pngPath)
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
            try await handle(request)
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
