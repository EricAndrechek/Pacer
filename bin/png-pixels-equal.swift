// png-pixels-equal — do two images have exactly the same pixels?
//
//   swiftc -O -o png-pixels-equal bin/png-pixels-equal.swift
//   png-pixels-equal a.png b.png     # exit 0: same pixels, 1: they differ, 2: unreadable
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

func samePixels(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return a.withUnsafeBytes { pa in
        b.withUnsafeBytes { pb in
            for i in 0..<pa.count {
                let x = pa[i], y = pb[i]
                if (x > y ? x - y : y - x) > tolerance { return false }
            }
            return true
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: png-pixels-equal <a.png> <b.png>\n".utf8))
    exit(2)
}
guard let a = pixels(of: args[0]), let b = pixels(of: args[1]) else {
    FileHandle.standardError.write(Data("png-pixels-equal: cannot read \(args[0]) or \(args[1])\n".utf8))
    exit(2)
}
exit(a.width == b.width && a.height == b.height && samePixels(a.bytes, b.bytes) ? 0 : 1)
