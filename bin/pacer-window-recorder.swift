// Records the area Pacer's dashboard occupies — and only Pacer's pixels in it —
// as timestamped PNGs.
//
//   swiftc -O bin/pacer-window-recorder.swift -o build/pacer-window-recorder
//   build/pacer-window-recorder <out-dir> <seconds> [bundle-id] [window-title]
//
// Used by bin/dev-record-relaunch.sh. THIS RECORDS THE SCREEN — see AGENTS.md;
// it runs only under the owner's go-ahead.
//
// Why ScreenCaptureKit and not `screencapture -R`: `screencapture -V -R` dims
// every display but the recorded rectangle for the whole recording, which takes
// the machine away from its owner. This dims nothing.
//
// Why a pre-started display stream and not a per-window one: starting a stream
// takes ~1 s, and a relaunch destroys the window and makes a new one — a stream
// started when the new window is spotted misses its first second, which is
// exactly when the layout shifts happen. So one stream starts *before* the
// relaunch, cropped to the dashboard's current frame, with a filter excluding
// every application running at that moment except Pacer. A relaunched Pacer is
// a new process and so is not excluded: its window is in frame from its first
// composite, and nothing else ever is — other apps' windows, the wallpaper
// (Dock) and the menu bar are excluded, so whatever is not Pacer is black. The
// area comes from where the window *is*; no monitor layout is guessed or kept.
//
// Output: <epoch-ms>.png per frame (only frames whose content changed), and
// events.txt — dashboard window appeared/moved/gone (the window server's list,
// polled every 20 ms) in ISO-8601 ms UTC, the same clock as Pacer's log.

import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: pacer-window-recorder <out> <seconds> [bundle] [title]\n".utf8))
    exit(64)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
let bundleID = args.count > 3 ? args[3] : "com.ericandrechek.pacer"
let title = args.count > 4 ? args[4] : "Dashboard"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let eventsURL = out.appendingPathComponent("events.txt")
FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
let events = try FileHandle(forWritingTo: eventsURL)
func event(_ s: String) {
    let line = "\(iso.string(from: Date())) \(s)\n"
    events.write(Data(line.utf8))
    print(line, terminator: "")
}
func fail(_ s: String) -> Never {
    event("error: \(s)")
    exit(1)
}

/// Dashboard windows on screen right now, from the window server's own list —
/// ~1 ms, cheap enough to poll every 20 ms for appear/move/disappear instants.
func dashboardWindows(requireTitle: Bool = false) -> [CGWindowID: CGRect] {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .map(\.processIdentifier))
    guard !pids.isEmpty,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
    var found: [CGWindowID: CGRect] = [:]
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
              // The title follows the tab ("History", "Settings"), so `title`
              // only picks the window at start; after that any normal-layer
              // window of the app big enough to be the main one counts.
              (info[kCGWindowLayer as String] as? Int) == 0,
              ((info[kCGWindowName as String] as? String) == title || !requireTitle),
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.width > 300, rect.height > 300 else { continue }
        found[id] = rect
    }
    return found
}

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "sink")
    let context = CIContext()
    var frames = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: out.appendingPathComponent("\(ms).png"))
        frames += 1
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        event("stream stopped: \(error.localizedDescription)")
    }
}

guard let frame = dashboardWindows(requireTitle: true).first?.value else {
    fail("no \"\(title)\" window of \(bundleID) on screen — open the dashboard first")
}
guard let content = try? await SCShareableContent.excludingDesktopWindows(
    false, onScreenWindowsOnly: true) else {
    fail("ScreenCaptureKit unavailable (Screen Recording permission for this terminal?)")
}
guard let display = content.displays.first(where: { $0.frame.intersects(frame) }) else {
    fail("no display contains the dashboard at \(frame)")
}
let others = content.applications.filter { $0.bundleIdentifier != bundleID }
let filter = SCContentFilter(display: display, excludingApplications: others, exceptingWindows: [])
let config = SCStreamConfiguration()
// Display-local points. 1× is enough to see a one-point shift and keeps a
// 60 fps burst of PNG writes cheap.
config.sourceRect = CGRect(x: frame.minX - display.frame.minX, y: frame.minY - display.frame.minY,
                           width: frame.width, height: frame.height)
config.width = Int(frame.width)
config.height = Int(frame.height)
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.showsCursor = false
config.capturesAudio = false
let sink = Sink()
let stream = SCStream(filter: filter, configuration: config, delegate: sink)
do {
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
    try await stream.startCapture()
} catch {
    fail("could not start capture: \(error.localizedDescription)")
}
event("ready — recording \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)) "
      + "(top-left coords) on display \(display.displayID), only \(bundleID), for \(Int(seconds))s")

var known = dashboardWindows()
for (id, r) in known { event("window w\(id) present at \(Int(r.minX)),\(Int(r.minY))") }
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    let now = dashboardWindows()
    for (id, r) in now where known[id] == nil {
        event("window w\(id) appeared at \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))")
    }
    for (id, r) in now where known[id] != nil && known[id] != r {
        event("window w\(id) moved to \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))")
    }
    for id in known.keys where now[id] == nil { event("window w\(id) gone") }
    known = now
    try? await Task.sleep(for: .milliseconds(20))
}
try? await stream.stopCapture()
event("done (\(sink.frames) frames)")
