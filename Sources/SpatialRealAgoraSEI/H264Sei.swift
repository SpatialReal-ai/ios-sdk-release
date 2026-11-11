import Foundation

/// H.264 Annex B 里的 SEI 读取(照 Web `facade/rtc/h264-sei.ts`)。
///
/// Agora 的编码帧回调交出整帧 Annex B(起始码 + NAL)。形象的数据在 SEI NAL(type 6)里,
/// SEI 消息的 payload type 是 101(Agora 自己的 metadata 载体,不是 UUID 型的 5)。
/// NAL 体是 EBSP:先去掉防竞争字节(`00 00 03` 里的 03)才是 RBSP,再按 SEI 语法逐条读。
package enum H264Sei {
    package static let agoraPayloadType = 101
    static let maxFrameBytes = 2 << 20
    static let maxNals = 64
    static let maxMessages = 16
    /// 突发模式下一条 SEI 实测到约 7.9 KB;留余量。
    static let maxPayloadBytes = 16 << 10

    package struct Result {
        package var payloads: [Data] = []
        /// 起始码、NAL 头、SEI 语法或外层封套不对的个数(诊断用)。
        package var malformed = 0
    }

    /// 一帧里所有 type 101 的 SEI 载荷,每个都已过了外层封套检查(`[1B flags][4B LE len]`,长度对得上)。
    package static func agoraPayloads(_ frame: Data) -> Result {
        var result = Result()
        guard frame.count <= maxFrameBytes else { result.malformed += 1; return result }
        let b = [UInt8](frame)
        guard var current = startCode(b, from: 0), b[0..<current.at].allSatisfy({ $0 == 0 }) else {
            result.malformed += 1
            return result
        }
        var nals = 0
        while true {
            nals += 1
            if nals > maxNals { break }
            let next = startCode(b, from: current.body)
            let end = next?.at ?? b.count
            if current.body < end {
                let header = b[current.body]
                if header & 0x80 != 0 {
                    result.malformed += 1
                } else if header & 0x1F == 6 {
                    readSei(b, from: current.body + 1, to: end, into: &result)
                }
            }
            guard let n = next else { break }
            current = n
        }
        return result
    }

    private static func readSei(_ b: [UInt8], from: Int, to: Int, into result: inout Result) {
        guard let data = rbsp(b, from: from, to: to) else { result.malformed += 1; return }
        var at = 0
        var messages = 0
        var found: [Data] = []
        func readExtended() -> Int? {
            var value = 0
            while at < data.count {
                let v = data[at]
                at += 1
                value += Int(v)
                if v != 0xFF { return value }
            }
            return nil
        }
        while at < data.count {
            // rbsp_trailing_bits:0x80 后全 0
            if data[at] == 0x80, data[(at + 1)...].allSatisfy({ $0 == 0 }) { break }
            messages += 1
            if messages > maxMessages { break }
            guard let type = readExtended(), let size = readExtended(), size <= data.count - at else {
                result.malformed += 1
                return
            }
            if type == agoraPayloadType {
                let payload = Data(data[at..<(at + size)])
                if size <= maxPayloadBytes, hasEnvelope(payload) { found.append(payload) } else { result.malformed += 1 }
            }
            at += size
        }
        result.payloads.append(contentsOf: found)
    }

    /// 外层封套:`[1B flags][4B LE len][len 字节]`,flags 最高位为 0,长度正好是剩下的字节数。
    package static func hasEnvelope(_ p: Data) -> Bool {
        guard p.count >= 5 else { return false }
        let s = p.startIndex
        guard p[s] & 0x80 == 0 else { return false }
        let len = UInt32(p[s + 1]) | UInt32(p[s + 2]) << 8 | UInt32(p[s + 3]) << 16 | UInt32(p[s + 4]) << 24
        return Int(len) == p.count - 5
    }

    /// 下一个起始码(`00 00 01` 或 `00 00 00 01`):at = 起始码开头,body = NAL 第一个字节。
    static func startCode(_ b: [UInt8], from: Int) -> (at: Int, body: Int)? {
        var i = from
        while i + 2 < b.count {
            if b[i] != 0 || b[i + 1] != 0 { i += 1; continue }
            if b[i + 2] == 1 { return (i, i + 3) }
            if i + 3 < b.count, b[i + 2] == 0, b[i + 3] == 1 { return (i, i + 4) }
            i += 1
        }
        return nil
    }

    /// EBSP → RBSP:两个 0 后的 03 是防竞争字节,去掉;03 后面只能跟 00..03。
    static func rbsp(_ b: [UInt8], from: Int, to: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(max(0, to - from))
        var zeros = 0
        var i = from
        while i < to {
            let v = b[i]
            if zeros >= 2, v == 3 {
                if i + 1 < to, b[i + 1] > 3 { return nil }
                zeros = 0
                i += 1
                continue
            }
            out.append(v)
            zeros = v == 0 ? zeros + 1 : 0
            i += 1
        }
        return out
    }
}
