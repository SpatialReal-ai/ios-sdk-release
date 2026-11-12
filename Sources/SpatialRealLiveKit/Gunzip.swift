import Compression
import Foundation

/// gzip decompression for animation packets (the server compresses them with gzip at best-speed level).
/// Strips the gzip header and trailer and hands the raw DEFLATE body to the Compression framework.
/// Output is capped at 16 MiB (taken from the gzip ISIZE trailer); returns nil on malformed input or a size mismatch.
enum Gunzip {
    private static let maxOutput = 16 << 20

    static func inflate(_ gz: Data) -> Data? {
        let b = [UInt8](gz)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flg = b[3]
        var pos = 10
        if flg & 0x04 != 0 { // FEXTRA
            guard b.count >= pos + 2 else { return nil }
            pos += 2 + (Int(b[pos]) | Int(b[pos + 1]) << 8)
        }
        if flg & 0x08 != 0 { // FNAME
            while pos < b.count, b[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flg & 0x10 != 0 { // FCOMMENT
            while pos < b.count, b[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flg & 0x02 != 0 { pos += 2 } // FHCRC
        guard b.count - 8 > pos else { return nil }
        let n = b.count
        let isize = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        guard isize >= 0, isize <= maxOutput else { return nil }
        return rawInflate(Array(b[pos ..< (n - 8)]), expected: isize)
    }

    private static func rawInflate(_ src: [UInt8], expected: Int) -> Data? {
        if expected == 0 { return Data() }
        var dst = [UInt8](repeating: 0, count: expected)
        let got = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, d.count, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard got == expected else { return nil }
        return Data(dst)
    }
}
