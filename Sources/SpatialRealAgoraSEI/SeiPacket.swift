import Compression
import Foundation

/// Header flags the server writes into each SEI payload (the same set as on the LiveKit data channel).
package enum SeiFlag {
    package static let idle = 0x01
    package static let start = 0x02
    package static let end = 0x04
    package static let gzipped = 0x08
    package static let transition = 0x10
    package static let transitionEnd = 0x20
    package static let redundant = 0x40
    package static let control = idle | transition | transitionEnd
}

/// The decoded contents of one SEI payload:
///
///     [1B flags][4B LE len][len bytes] — the len bytes are escape(zlib(payload)); the 5-byte header is not escaped
///     Content packet, inflated: [4B LE frameSeq][Message]; with Redundant: [4B seq][4B len][cur][4B len][p1][4B len][p2]
///     Control packet (Idle / Transition / TransitionEnd), inflated: one bare Message, possibly empty
///
/// The source timeline deduplicates audio and poses by sample position, so no frameSeq deduplication happens here;
/// every Message in the carrier is returned.
package struct SeiPacket: Equatable {
    package let flags: Int
    /// The `driveningress.v2.Message` bytes in the carrier (in the redundant layout, the current one is last).
    package let messages: [Data]

    package var isControl: Bool { flags & SeiFlag.control != 0 }

    static let headerSize = 5
    /// Inflate limit: no valid payload comes close to this (burst-mode payloads measure tens of KB).
    static let maxInflated = 4 << 20

    package enum Failure: Error, Equatable {
        case envelope, unescape, inflate, payload
    }

    package static func decode(_ sei: Data) -> Result<SeiPacket, Failure> {
        let b = [UInt8](sei)
        guard b.count >= headerSize else { return .failure(.envelope) }
        let flags = Int(b[0])
        let len = Int(UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24)
        guard b.count >= headerSize + len else { return .failure(.envelope) }
        let control = flags & SeiFlag.control != 0
        if len == 0 { return control ? .success(SeiPacket(flags: flags, messages: [])) : .failure(.payload) }
        guard let unescaped = unescape(b[headerSize..<(headerSize + len)]) else { return .failure(.unescape) }
        let raw: [UInt8]
        if flags & SeiFlag.gzipped != 0 {
            guard let inflated = inflateZlib(unescaped) else { return .failure(.inflate) }
            raw = inflated
        } else {
            raw = unescaped
        }
        if control { return .success(SeiPacket(flags: flags, messages: raw.isEmpty ? [] : [Data(raw)])) }
        guard let messages = payload(raw, redundant: flags & SeiFlag.redundant != 0), !messages.isEmpty else { return .failure(.payload) }
        return .success(SeiPacket(flags: flags, messages: messages))
    }

    /// Reverses the server's byte escaping: every 0x00 / 0xFF is followed by a 0xFF padding byte, which is removed.
    /// Returns nil if the padding is wrong.
    static func unescape(_ p: ArraySlice<UInt8>) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(p.count)
        var i = p.startIndex
        while i < p.endIndex {
            let v = p[i]
            out.append(v)
            if v == 0x00 || v == 0xFF {
                guard i + 1 < p.endIndex, p[i + 1] == 0xFF else { return nil }
                i += 1
            }
            i += 1
        }
        return out
    }

    /// Inflated payload → list of Messages. The redundant layout is reordered so older ones come first, i.e. in time
    /// order.
    static func payload(_ raw: [UInt8], redundant: Bool) -> [Data]? {
        guard raw.count >= 4 else { return nil }
        if !redundant { return raw.count > 4 ? [Data(raw[4...])] : nil }
        var off = 4
        var parts: [Data] = []
        while off + 4 <= raw.count {
            let n = Int(UInt32(raw[off]) | UInt32(raw[off + 1]) << 8 | UInt32(raw[off + 2]) << 16 | UInt32(raw[off + 3]) << 24)
            off += 4
            guard n <= raw.count - off else { return parts.isEmpty ? nil : parts.reversed() }
            if n > 0 { parts.append(Data(raw[off..<(off + n)])) }
            off += n
        }
        return parts.isEmpty ? nil : parts.reversed()
    }

    /// zlib stream (RFC 1950: 2-byte header + DEFLATE + Adler-32). Apple's Compression `ZLIB` is raw DEFLATE, so
    /// the header is stripped here.
    static func inflateZlib(_ z: [UInt8]) -> [UInt8]? {
        guard z.count >= 6 else { return nil }
        let cmf = Int(z[0]), flg = Int(z[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else { return nil }
        return inflateRaw(Array(z[2...]))
    }

    private static func inflateRaw(_ src: [UInt8]) -> [UInt8]? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 << 10
        var out = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: chunk)
        return src.withUnsafeBufferPointer { s -> [UInt8]? in
            stream.pointee.src_ptr = s.baseAddress!
            stream.pointee.src_size = s.count
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { d -> compression_status in
                    stream.pointee.dst_ptr = d.baseAddress!
                    stream.pointee.dst_size = chunk
                    // No FINALIZE: the 4-byte Adler-32 trails the stream, and DEFLATE knows where it ends.
                    return compression_stream_process(stream, 0)
                }
                let produced = chunk - stream.pointee.dst_size
                out.append(contentsOf: buffer[0..<produced])
                if out.count > maxInflated { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK:
                    // Input consumed and nothing produced: the stream is truncated.
                    if produced == 0, stream.pointee.src_size == 0 { return nil }
                default: return nil
                }
            }
        }
    }
}
