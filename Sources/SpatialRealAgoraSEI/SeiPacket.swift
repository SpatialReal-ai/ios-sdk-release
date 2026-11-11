import Compression
import Foundation

/// egress 写进 SEI 的包头 flags(backend-ng `internal/egress/providers/agora/animation_track.go`;和 LiveKit 数据通道同一套)。
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

/// 一条 SEI 载荷解出来的东西(照 Web `facade/rtc/sei-packet.ts`):
///
///     [1B flags][4B LE len][len 字节] —— 这 len 字节是 escape(zlib(payload)),5 字节头不转义
///     内容包解压后:[4B LE frameSeq][Message];带 Redundant:[4B seq][4B len][cur][4B len][p1][4B len][p2]
///     控制包(Idle / Transition / TransitionEnd)解压后是一条裸 Message,可能为空
///
/// 源时间线的音频和姿态都按样本坐标去重,所以这里不做 frameSeq 去重,把载体里的每条 Message 都交出去。
package struct SeiPacket: Equatable {
    package let flags: Int
    /// 载体里的 `driveningress.v2.Message` 字节(冗余布局下当前的在最后)。
    package let messages: [Data]

    package var isControl: Bool { flags & SeiFlag.control != 0 }

    static let headerSize = 5
    /// 解压上限:一条载荷不可能解出这么多(突发模式实测几十 KB)。
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

    /// egress 的 escapeZeroBytes 反过来:每个 0x00 / 0xFF 后面跟一个 0xFF 填充字节,去掉。填充不对返回 nil。
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

    /// 解压后的载荷 → Message 列表。冗余布局把旧的放前面,按时间顺序交出。
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

    /// zlib 流(RFC 1950:2 字节头 + DEFLATE + Adler-32)。Compression 的 ZLIB 是裸 DEFLATE,头自己剥。
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
                    // 不带 FINALIZE:流末尾还有 Adler-32 四个字节,DEFLATE 自己知道在哪结束
                    return compression_stream_process(stream, 0)
                }
                let produced = chunk - stream.pointee.dst_size
                out.append(contentsOf: buffer[0..<produced])
                if out.count > maxInflated { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK:
                    // 输入吃完、也没产出:流被截断
                    if produced == 0, stream.pointee.src_size == 0 { return nil }
                default: return nil
                }
            }
        }
    }
}
