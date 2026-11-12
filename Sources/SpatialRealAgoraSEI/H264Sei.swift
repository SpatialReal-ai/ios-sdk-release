import Foundation

/// Reads SEI from H.264 Annex B frames.
///
/// Agora's encoded frame callback delivers whole Annex B frames (start codes + NAL units). The avatar data is in SEI
/// NAL units (type 6) whose SEI messages use payload type 101 (Agora's own metadata carrier, not the UUID-based 5).
/// The NAL body is EBSP: emulation prevention bytes (the 03 in `00 00 03`) are removed to get RBSP, which is then read
/// message by message using SEI syntax.
package enum H264Sei {
    package static let agoraPayloadType = 101
    static let maxFrameBytes = 2 << 20
    static let maxNals = 64
    static let maxMessages = 16
    /// In burst mode a single SEI has been measured at about 7.9 KB; this leaves headroom.
    static let maxPayloadBytes = 16 << 10

    package struct Result {
        package var payloads: [Data] = []
        /// Number of bad start codes, NAL headers, SEI syntax or outer envelopes (for diagnostics).
        package var malformed = 0
    }

    /// All type-101 SEI payloads in a frame, each already past the outer envelope check (`[1B flags][4B LE len]`
    /// with a matching length).
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
            // rbsp_trailing_bits: 0x80 followed by all zeros
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

    /// Outer envelope: `[1B flags][4B LE len][len bytes]`, the top bit of flags is 0, and len equals the remaining
    /// byte count exactly.
    package static func hasEnvelope(_ p: Data) -> Bool {
        guard p.count >= 5 else { return false }
        let s = p.startIndex
        guard p[s] & 0x80 == 0 else { return false }
        let len = UInt32(p[s + 1]) | UInt32(p[s + 2]) << 8 | UInt32(p[s + 3]) << 16 | UInt32(p[s + 4]) << 24
        return Int(len) == p.count - 5
    }

    /// Next start code (`00 00 01` or `00 00 00 01`): `at` = start of the start code, `body` = first byte of the NAL.
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

    /// EBSP → RBSP: a 03 after two zero bytes is an emulation prevention byte and is removed; it may only be followed
    /// by 00..03.
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
