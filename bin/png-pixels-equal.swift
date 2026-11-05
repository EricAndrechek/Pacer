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
// One exception to "no count" (#291): a widget card's edge and shadow can land a
// fraction of a pixel off between runs. On a real pair that moved ~5,800 pixels
// by 3-8 levels in a band 19 px wide and 342 long (the shadow), plus 14 pixels
// by a lot in a 3 x 270 strip (the anti-aliased edge itself). That is told apart
// from a real change by SHAPE, not size, in two tiers:
//   - every pixel past `tolerance` lies in one band: short side <= `edgeBand`,
//     long side >= `edgeAspect` times the short one;
//   - the pixels that moved a lot (past `faint` levels) number at most
//     `edgeBudget` and themselves form a sliver: short side <= `edgeThickness`,
//     long side >= `edgeAspect` times it.
// A glyph or label change moves hundreds of pixels by tens of levels in a blob,
// so it still counts, even inside a band-shaped row. The tolerated region is
// logged to stderr.

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
let faint: UInt8 = 16
let edgeBudget = 64
let edgeThickness = 4
let edgeBand = 24
let edgeAspect = 8

/// Bounding box of the pixels added to it.
struct Box {
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    var count = 0
    mutating func add(_ x: Int, _ y: Int) {
        count += 1
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    /// Short side at most `thickness`, long side at least `edgeAspect` times it.
    func isStrip(thickness: Int) -> Bool {
        let thin = min(width, height), long = max(width, height)
        return thin <= thickness && long >= thin * edgeAspect
    }
}

func samePixels(_ a: Data, _ b: Data, width: Int, height: Int, rects: [CGRect]?) -> Bool {
    guard a.count == b.count else { return false }
    let regions = rects ?? [CGRect(x: 0, y: 0, width: width, height: height)]
    var moved = Box()   // past `tolerance`
    var strong = Box()  // past `faint`
    let over: Bool = a.withUnsafeBytes { pa in
        b.withUnsafeBytes { pb in
            for r in regions {
                let x0 = max(0, Int(r.minX)), x1 = min(width, Int(r.maxX))
                let y0 = max(0, Int(r.minY)), y1 = min(height, Int(r.maxY))
                guard x0 < x1, y0 < y1 else { continue }
                for row in y0..<y1 {
                    for col in x0..<x1 {
                        let i = (row * width + col) * 4
                        var delta: UInt8 = 0
                        for c in 0..<4 {
                            let p = pa[i + c], q = pb[i + c]
                            delta = max(delta, p > q ? p - q : q - p)
                        }
                        guard delta > tolerance else { continue }
                        moved.add(col, row)
                        if delta > faint {
                            strong.add(col, row)
                            if strong.count > edgeBudget { return true }
                        }
                    }
                }
            }
            return false
        }
    }
    if over { return false }
    if moved.count == 0 { return true }
    guard moved.isStrip(thickness: edgeBand),
          strong.count == 0 || strong.isStrip(thickness: edgeThickness) else { return false }
    FileHandle.standardError.write(Data(
        ("png-pixels-equal: ignoring an edge: \(moved.count) faint pixels in "
         + "x=\(moved.minX) y=\(moved.minY) \(moved.width)x\(moved.height), "
         + "\(strong.count) strong\n").utf8))
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
