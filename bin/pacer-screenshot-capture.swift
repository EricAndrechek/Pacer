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
    // Then a real macOS wallpaper, or the bar sits on a black desktop.
    // The main display, so the menu bar the menu-bar scenes photograph is this
    // 2× one. By mirroring the runner's own display onto it, not by moving
    // display origins: moved, the runner drew the text of Pacer's SwiftUI
    // status-item label upside down (a plain title was fine, and so is every
    // real Mac — checked on the owner's three displays). Restarting the
    // menu-bar processes did not help; mirroring did.
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
    /// "window": crop to this rectangle of the window (points, top-left) —
    /// one card of the real window.
    var crop: [Double]?
    var dark: Bool?
    var done: String?
    // "widgetsim" / "gallery" (widgets.png — see captureWidgetSim).
    var debug: String?
    var rows: [[String]]?
}

func fail(_ s: String) -> NSError { NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

func handle(_ request: Request) async throws {
    switch request.kind ?? "window" {
    case "window": try await capture(request)
    case "menubar": try await captureMenuBar(request)
    case "appearance": try setDarkMode(request.dark ?? false)
    case "widgetsim": try await captureWidgetSim(request)
    case "gallery": try composeGallery(request)
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
    // Only Pacer's own item in the bar. The rest belong to other processes
    // (Spotlight, Control Center, the system clock) and draw what the
    // screenshot run's pinned clock cannot reach: the runner's real date,
    // and the screen-recording dot this very capture turns on, in some runs
    // and not others (#154). Left out, the bar behind them shows instead.
    //
    // "In the bar" is a thin window at the top of the display. Not
    // `NSStatusBar.thickness` tall: on macOS 26 the bar is taller than its
    // items, and a filter sized to the items excluded nothing.
    let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
    let inBar = content.windows.filter { window in
        window.frame.minY >= display.frame.minY - 1
            && window.frame.minY < display.frame.minY + 60
            && window.frame.height <= 60
    }
    for window in inBar {
        log("menubar: bar window \(window.owningApplication?.bundleIdentifier ?? "-")"
            + " '\(window.title ?? "")' layer \(window.windowLayer) \(window.frame)")
    }
    let others = inBar.filter {
        $0.windowLayer >= statusLevel
            && $0.owningApplication?.bundleIdentifier != "com.ericandrechek.pacer"
    }
    log("menubar: leaving out \(others.count) of \(inBar.count) bar window(s)")
    let filter = SCContentFilter(display: display, excludingWindows: others)
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
    let crop = request.crop
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
    config.showsCursor = false
    config.captureResolution = .best
    if crop == nil {
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        // The window's real shadow, on a transparent margin — what a macOS window
        // screenshot looks like, and what the README's images have always had.
        config.ignoreShadowsSingleWindow = false
    } else {
        // No shadow, so the image is exactly the window's frame and the crop,
        // in window points, maps straight onto it.
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.ignoreShadowsSingleWindow = true
    }
    log("capturing \(window.frame) level \(window.windowLayer) onScreen \(window.isOnScreen)")
    var image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
    if let c = crop, c.count == 4 {
        let px = Double(image.width) / window.frame.width
        let rect = CGRect(x: c[0] * px, y: c[1] * px, width: c[2] * px, height: c[3] * px).integral
        guard let cropped = image.cropping(to: rect) else { throw fail("window: crop \(rect) outside \(image.width)×\(image.height)") }
        image = cropped
    }
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try png.write(to: URL(fileURLWithPath: request.png))
    log("✓ \(URL(fileURLWithPath: request.png).lastPathComponent) (\(image.width)×\(image.height))")
}

// MARK: - Widgets (widgets.png), from WidgetKit Simulator

// The home-screen widgets are the real PacerWidgets extension, rendered by
// Apple's WidgetKit Simulator (bin/widgetkit-sim-shots.sh opens it on one
// widget kind at a time). `widgetsim` photographs the simulator's document
// window, finds the widget card in it, and writes just the card: the system's
// own rendering — corner mask, background, content margins and shadow — with
// the simulator's white page turned transparent. `gallery` lays those crops
// out in rows. Nothing here draws any part of a widget.

/// RGBA8, premultiplied, sRGB — one pixel is four bytes at `(y * width + x) * 4`.
struct Bitmap {
    let width: Int, height: Int
    var data: [UInt8]
    init(_ image: CGImage) {
        width = image.width; height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    init(width: Int, height: Int) {
        self.width = width; self.height = height
        data = [UInt8](repeating: 0, count: width * height * 4)
    }
    func luma(_ x: Int, _ y: Int) -> Int {
        let i = (y * width + x) * 4
        return (Int(data[i]) * 299 + Int(data[i + 1]) * 587 + Int(data[i + 2]) * 114) / 1000
    }
    func cgImage() -> CGImage {
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

func writePNG(_ image: CGImage, to path: String) throws {
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw fail("PNG encoding failed")
    }
    try png.write(to: URL(fileURLWithPath: path))
}

/// The card in the simulator's page: the widget's white background, fenced
/// off from the white page around it by the card's own shadow. `spans[row]`
/// is the card's horizontal extent on that row — its real, rounded outline.
struct Card: Equatable {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var spans: [Int: ClosedRange<Int>]
    var size: (Int, Int) { (maxX - minX + 1, maxY - minY + 1) }
    static func == (a: Card, b: Card) -> Bool {
        a.minX == b.minX && a.minY == b.minY && a.maxX == b.maxX && a.maxY == b.maxY
    }
}

func findCard(in bmp: Bitmap, scale: Double) -> Card? {
    let w = bmp.width, h = bmp.height
    // Near-white, as the page and a light-mode widget both are; the shadow
    // ring between them is darker than this all the way round.
    var white = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w where bmp.luma(x, y) >= 251 { white[y * w + x] = true } }
    var label = [Int32](repeating: -1, count: w * h)
    var best: (card: Card, area: Int)?
    var stack: [Int] = []
    var next: Int32 = 0
    for start in 0..<(w * h) where white[start] && label[start] < 0 {
        var minX = w, minY = h, maxX = 0, maxY = 0, count = 0, touchesEdge = false
        var spans: [Int: ClosedRange<Int>] = [:]
        stack.append(start); label[start] = next
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            count += 1
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            if let s = spans[y] { spans[y] = min(s.lowerBound, x)...max(s.upperBound, x) } else { spans[y] = x...x }
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesEdge = true }
            for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
            where j >= 0 && white[j] && label[j] < 0 {
                label[j] = next; stack.append(j)
            }
        }
        next += 1
        // The page itself reaches the window's edge; a widget is between a
        // small (~158 pt) and a medium (~364 pt) — large is not photographed.
        let bw = Double(maxX - minX + 1) / scale, bh = Double(maxY - minY + 1) / scale
        guard !touchesEdge, (120...420).contains(bw), (120...420).contains(bh),
              Double(count) / (Double(maxX - minX + 1) * Double(maxY - minY + 1)) > 0.3 else { continue }
        let area = (maxX - minX + 1) * (maxY - minY + 1)
        if area > (best?.area ?? 0) {
            best = (Card(minX: minX, minY: minY, maxX: maxX, maxY: maxY, spans: spans), area)
        }
    }
    return best?.card
}

func simulatorDocumentWindow() async throws -> SCWindow? {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    return content.windows
        .filter { $0.owningApplication?.bundleIdentifier == "com.apple.widgetkit.simulator"
            && $0.windowLayer == 0 && $0.frame.width > 400 && $0.frame.height > 300 }
        .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

func captureWidgetSim(_ request: Request) async throws {
    guard ProcessInfo.processInfo.environment["CI"] == "true" else { throw fail("widgetsim: CI only") }
    guard let png = request.png else { throw fail("widgetsim: png required") }
    let name = URL(fileURLWithPath: png).lastPathComponent
    // The simulator launches, loads the extension and asks it for a timeline:
    // seconds on a cold runner. Wait for the same card in two frames running.
    var last: Card?
    var image: CGImage?
    var scale = 1.0
    var windowFrame = CGRect.zero
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
        try await Task.sleep(for: .milliseconds(800))
        guard let window = try await simulatorDocumentWindow() else { continue }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        scale = Double(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        image = shot; windowFrame = window.frame
        let card = findCard(in: Bitmap(shot), scale: scale)
        if let card, card == last { break }
        last = card
    }
    if let debug = request.debug, let image { try writePNG(image, to: debug) }
    guard let image else { throw fail("widgetsim \(name): no WidgetKit Simulator document window") }
    guard let card = last else { throw fail("widgetsim \(name): no widget card found in the window") }
    log("\(name): window \(windowFrame) @\(scale)×, card \(card.size.0)×\(card.size.1) px at (\(card.minX), \(card.minY))")

    // A margin wide enough for most of the shadow — but short of the entry's
    // date label beneath the card in the Timeline tab: text is darker than
    // any of the shadow, so the margin stops a row above the first text.
    // The same margin all round, so the card sits centred in its crop.
    let src = Bitmap(image)
    var m = Int((8 * scale).rounded())
    for y in (card.maxY + 1)...min(src.height - 1, card.maxY + m)
    where (card.minX...card.maxX).contains(where: { src.luma($0, y) < 190 }) {
        m = max(0, y - card.maxY - 2); break
    }
    let x0 = max(0, card.minX - m), y0 = max(0, card.minY - m)
    let x1 = min(src.width - 1, card.maxX + m), y1 = min(src.height - 1, card.maxY + m)
    var out = Bitmap(width: x1 - x0 + 1, height: y1 - y0 + 1)
    for y in y0...y1 {
        for x in x0...x1 {
            let si = (y * src.width + x) * 4, oi = ((y - y0) * out.width + (x - x0)) * 4
            if let span = card.spans[y], span.contains(x) {
                // The card: exactly as the system drew it.
                for c in 0..<4 { out.data[oi + c] = src.data[si + c] }
                out.data[oi + 3] = 255
            } else {
                // The page around it: white under a black shadow, so a pixel's
                // darkness is the shadow's opacity. Kept as that — a black
                // shadow on transparency — rather than the page's white, which
                // would sit as a white box on a dark README.
                // The margin stops short of where the shadow does, so it is
                // faded out over the crop's outer 4 pt: cut off instead, it
                // leaves a faint hard-edged box round each widget in the gallery.
                out.data[oi] = 0; out.data[oi + 1] = 0; out.data[oi + 2] = 0
                let edge = min(x - x0, x1 - x, y - y0, y1 - y)
                let fade = min(1, Double(edge) / max(1, 4 * scale))
                out.data[oi + 3] = UInt8(Double(max(0, 255 - src.luma(x, y))) * fade)
            }
        }
    }
    try writePNG(out.cgImage(), to: png)
    log("✓ \(name) (\(out.width)×\(out.height), WidgetKit Simulator)")
}

/// Rows of crops, centred, on transparency — the README's widget gallery.
func composeGallery(_ request: Request) throws {
    guard let rows = request.rows, let png = request.png else { throw fail("gallery: rows and png required") }
    let images: [[CGImage]] = try rows.map { row in
        try row.map { path in
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw fail("gallery: cannot read \(path)") }
            return image
        }
    }
    // Pixels at 2×. Each crop carries a few points of its shadow, so 14 pt
    // between crops reads as the old gallery's ~22 pt between cards.
    let gap = 28, pad = 40
    let rowWidths = images.map { $0.reduce(0) { $0 + $1.width } + gap * max(0, $0.count - 1) }
    let rowHeights = images.map { $0.map(\.height).max() ?? 0 }
    let width = (rowWidths.max() ?? 0) + 2 * pad
    let height = rowHeights.reduce(0, +) + gap * max(0, images.count - 1) + 2 * pad
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var top = pad
    for (r, row) in images.enumerated() {
        var x = (width - rowWidths[r]) / 2
        for image in row {
            // CoreGraphics is bottom-up; rows are laid out top-down.
            ctx.draw(image, in: CGRect(x: x, y: height - top - image.height, width: image.width, height: image.height))
            x += image.width + gap
        }
        top += rowHeights[r] + gap
    }
    try writePNG(ctx.makeImage()!, to: png)
    log("✓ \(URL(fileURLWithPath: png).lastPathComponent) (\(width)×\(height), \(images.joined().count) widgets)")
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
