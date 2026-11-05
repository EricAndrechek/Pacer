// png-pixels-equal — do two images have exactly the same pixels?
//
//   swiftc -O -o png-pixels-equal bin/png-pixels-equal.swift
//   png-pixels-equal a.png b.png [rects.json]
//       # exit 0: same pixels, 1: they differ, 2: unreadable
//
// With a rects.json (`{"rects": [[x, y, w, h], …]}`, image pixels, top-left
// origin — written by pacer-screenshot-capture beside a menu bar shot), only
// the pixels inside those rectangles are compared: Pacer's own windows. The
// desktop behind a translucent menu is not ours and drifted between runs
// hours apart (#166); the rectangles are the windows' frames, so what the
// window draws of the desktop through itself is still compared. Sizes must
// still match. Without a sidecar, or an unreadable one, the whole image.
//
// Used by .github/workflows/screenshots.yml to drop re-rendered README images
// whose pixels did not change. A render re-encodes every image, so an
// unchanged one still comes out byte-different, and committing it adds a
// review item and another copy in git history for nothing (#154).
//
// No threshold on how MANY pixels differ: a real one-label UI change is about
// as small, by that count, as rendering noise, so a count loose enough to hide
// the noise would also hide a real change. The tolerance is on how FAR a pixel
// moves instead, at most `tolerance` levels (of 255) on any channel. The noise
// is that faint (translucent toolbar material came out 1-2 levels different
// between two identical runs, #154), and a real change is not: a glyph's edge
// moves by tens or hundreds of levels.
//
// One exception to "no count" (#291): a card's rounded edge can land a pixel
// off between runs, which moves ~14 pixels by a lot, in a strip 3 px wide and
// 270 long. That is told apart from a real change by SHAPE, not size: at most
// `edgeBudget` pixels past the tolerance, whose bounding box is a thin sliver
// (short side <= `edgeThickness`, long side >= `edgeAspect` times the short
// one). A glyph or a label change is blob-shaped and far bigger, so it still
// counts. The tolerated region is logged to stderr.
//
// Both images are drawn into the same 8-bit sRGB bitmap and the bytes are
// compared, so two encodings of one picture (different compression, chunk
// order, stripped metadata) compare equal.

import CoreGraphics
import Foundation
import ImageIO

func pixels(of path: String) -> (width: Int, height: Int, bytes: Data)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
              bytesPerRow: image.width * 4, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let base = context.data else { return nil }
    return (image.width, image.height, Data(bytes: base, count: image.width * image.height * 4))
}

let tolerance: UInt8 = 2
let edgeBudget = 64
let edgeThickness = 4
let edgeAspect = 8

func samePixels(_ a: Data, _ b: Data, width: Int, height: Int, rects: [CGRect]?) -> Bool {
    guard a.count == b.count else { return false }
    let regions = rects ?? [CGRect(x: 0, y: 0, width: width, height: height)]
    var count = 0
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    let over: Bool = a.withUnsafeBytes { pa in
        b.withUnsafeBytes { pb in
            for r in regions {
                let x0 = max(0, Int(r.minX)), x1 = min(width, Int(r.maxX))
                let y0 = max(0, Int(r.minY)), y1 = min(height, Int(r.maxY))
                guard x0 < x1, y0 < y1 else { continue }
                for row in y0..<y1 {
                    for col in x0..<x1 {
                        let i = (row * width + col) * 4
                        var differs = false
                        for c in 0..<4 {
                            let p = pa[i + c], q = pb[i + c]
                            if (p > q ? p - q : q - p) > tolerance { differs = true }
                        }
                        guard differs else { continue }
                        count += 1
                        if count > edgeBudget { return true }
                        minX = min(minX, col); maxX = max(maxX, col)
                        minY = min(minY, row); maxY = max(maxY, row)
                    }
                }
            }
            return false
        }
    }
    if over { return false }
    if count == 0 { return true }
    let w = maxX - minX + 1, h = maxY - minY + 1
    let thin = min(w, h), long = max(w, h)
    guard thin <= edgeThickness, long >= thin * edgeAspect else { return false }
    FileHandle.standardError.write(Data(
        "png-pixels-equal: ignoring \(count) edge pixels in x=\(minX) y=\(minY) \(w)x\(h)\n".utf8))
    return true
}

func sidecarRects(_ path: String) -> [CGRect]? {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = json["rects"] as? [[Double]], !list.isEmpty else { return nil }
    return list.compactMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 || args.count == 3 else {
    FileHandle.standardError.write(Data("usage: png-pixels-equal <a.png> <b.png> [rects.json]\n".utf8))
    exit(2)
}
guard let a = pixels(of: args[0]), let b = pixels(of: args[1]) else {
    FileHandle.standardError.write(Data("png-pixels-equal: cannot read \(args[0]) or \(args[1])\n".utf8))
    exit(2)
}
let rects = args.count == 3 ? sidecarRects(args[2]) : nil
exit(a.width == b.width && a.height == b.height
    && samePixels(a.bytes, b.bytes, width: a.width, height: a.height, rects: rects) ? 0 : 1)
