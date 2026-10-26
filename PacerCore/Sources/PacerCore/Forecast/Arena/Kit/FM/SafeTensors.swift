import Foundation

/// A minimal `.safetensors` reader: an 8-byte little-endian header length,
/// a JSON header (`{name: {dtype, shape, data_offsets: [begin, end]}}`,
/// plus `__metadata__`), then the tensors' bytes, little-endian.
///
/// The file is memory-mapped read-only and kept mapped for the reader's
/// lifetime: float32 tensors are read in place (file-backed pages the system
/// can drop and re-read under memory pressure, instead of 800 MB of dirty
/// heap for the largest Timestral), and float16 / bfloat16 tensors are
/// widened to float32 once, on first access.
public final class SafeTensors: @unchecked Sendable {
    public struct Entry: Sendable {
        public let dtype: String
        public let shape: [Int]
        public let begin: Int
        public let end: Int
        public var count: Int { shape.reduce(1, *) }
    }

    public enum ReadError: Error, CustomStringConvertible {
        case open(String), truncated(String), header(String), missing(String), dtype(String, String), shape(String)
        public var description: String {
            switch self {
            case .open(let p): "cannot open \(p)"
            case .truncated(let p): "\(p) is truncated"
            case .header(let s): "bad safetensors header: \(s)"
            case .missing(let n): "tensor \(n) not in the file"
            case .dtype(let n, let d): "tensor \(n) has unsupported dtype \(d)"
            case .shape(let s): s
            }
        }
    }

    public let url: URL
    public let entries: [String: Entry]
    private let base: UnsafeRawPointer
    private let length: Int
    private let dataStart: Int
    private var widened: [String: UnsafeMutablePointer<Float>] = [:]
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ReadError.open(url.path) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= 8 else { throw ReadError.truncated(url.path) }
        let len = Int(st.st_size)
        guard let p = mmap(nil, len, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            throw ReadError.open(url.path)
        }
        let raw = UnsafeRawPointer(p)
        var headerLen: UInt64 = 0
        withUnsafeMutableBytes(of: &headerLen) { $0.copyMemory(from: UnsafeRawBufferPointer(start: raw, count: 8)) }
        headerLen = UInt64(littleEndian: headerLen)
        guard headerLen < UInt64(len - 8) else { munmap(p, len); throw ReadError.truncated(url.path) }
        let headerData = Data(bytes: raw + 8, count: Int(headerLen))
        guard let json = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            munmap(p, len); throw ReadError.header("not a JSON object")
        }
        var entries: [String: Entry] = [:]
        let start = 8 + Int(headerLen)
        for (name, value) in json where name != "__metadata__" {
            guard let d = value as? [String: Any], let dtype = d["dtype"] as? String,
                  let shape = (d["shape"] as? [NSNumber])?.map(\.intValue),
                  let offs = (d["data_offsets"] as? [NSNumber])?.map(\.intValue), offs.count == 2,
                  offs[0] <= offs[1], start + offs[1] <= len
            else { munmap(p, len); throw ReadError.header("entry \(name)") }
            entries[name] = Entry(dtype: dtype, shape: shape, begin: offs[0], end: offs[1])
        }
        self.entries = entries
        self.base = raw
        self.length = len
        self.dataStart = start
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), length)
        for p in widened.values { p.deallocate() }
    }

    /// The tensor as float32, read in place when stored as float32 (and
    /// aligned), else widened once and kept. Valid while the reader lives.
    public func floats(_ name: String, shape expected: [Int]? = nil) throws -> UnsafePointer<Float> {
        guard let e = entries[name] else { throw ReadError.missing(name) }
        if let expected, expected != e.shape {
            throw ReadError.shape("tensor \(name) is \(e.shape), expected \(expected)")
        }
        let p = base + dataStart + e.begin
        let n = e.count
        switch e.dtype {
        case "F32":
            guard e.end - e.begin == 4 * n else { throw ReadError.header("size of \(name)") }
            if Int(bitPattern: p) % MemoryLayout<Float>.alignment == 0 {
                return p.assumingMemoryBound(to: Float.self)
            }
            return widen(name, n) { out in
                for i in 0..<n { out[i] = Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))) }
            }
        case "F16":
            guard e.end - e.begin == 2 * n else { throw ReadError.header("size of \(name)") }
            return widen(name, n) { out in
                for i in 0..<n { out[i] = Self.halfToFloat(UInt16(littleEndian: p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))) }
            }
        case "BF16":
            guard e.end - e.begin == 2 * n else { throw ReadError.header("size of \(name)") }
            return widen(name, n) { out in
                for i in 0..<n {
                    let b = UInt16(littleEndian: p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
                    out[i] = Float(bitPattern: UInt32(b) << 16)
                }
            }
        default:
            throw ReadError.dtype(name, e.dtype)
        }
    }

    /// IEEE 754 binary16 to float32, exactly. By hand rather than through
    /// `Float16`, which Swift does not offer on Intel Macs (the app's release
    /// build is universal).
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = Int((h >> 10) & 0x1f)
        let mant = UInt32(h & 0x3ff)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            let v = Float(mant) * 0x1p-24                    // subnormal: mant · 2^-24
            return sign != 0 ? -v : v
        }
        if exp == 31 { return Float(bitPattern: sign | 0x7f80_0000 | (mant << 13)) }   // inf / NaN
        return Float(bitPattern: sign | (UInt32(exp + 112) << 23) | (mant << 13))
    }

    private func widen(_ name: String, _ n: Int, _ fill: (UnsafeMutablePointer<Float>) -> Void) -> UnsafePointer<Float> {
        lock.lock(); defer { lock.unlock() }
        if let p = widened[name] { return UnsafePointer(p) }
        let p = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1))
        fill(p)
        widened[name] = p
        return UnsafePointer(p)
    }
}
