import Foundation

/// Animation packet decoder (LiveKit data channel, topic `spatialreal-animation`).
///
/// Wire format (all integers are little-endian uint32 unless noted):
///
///     [1B flags][4B len][len bytes of payload, gzip-compressed when the Gzipped flag is set]
///     payload:               [4B frameSeq][animation `Message` bytes (protobuf)]
///     payload with Redundant: [4B frameSeq][4B curLen][cur][4B p1Len][p1][4B p2Len][p2]
///
/// With Redundant, `cur` is frame `frameSeq` and `p1` / `p2` repeat frames `frameSeq - 1` / `frameSeq - 2`
/// so a lost packet can be recovered; a zero length means the slot is empty.
/// Idle packets are just the 5-byte header; transition payloads are not parsed (only the flags are used).
/// The decoder drops duplicates by frameSeq, fills small gaps, and treats a large gap as a new stream (resync).
enum PacketFlag {
    static let idle = 0x01
    static let start = 0x02
    static let end = 0x04
    static let gzipped = 0x08
    static let transition = 0x10
    static let transitionEnd = 0x20
    static let redundant = 0x40
}

struct DecodedPacket {
    let flags: Int
    /// `Message` bytes produced by this packet, in frame order; empty for idle, transition and duplicate packets.
    let messages: [Data]
    /// Set when a gap is too large to fill: the caller should reset the current turn.
    let resync: Bool
}

final class AnimationPacketDecoder {
    private static let header = 5
    private static let noSeq: Int64 = -1
    /// Maximum number of missing frames filled by repeating the last frame (400 ms at 25 fps); a larger gap counts as a broken stream.
    private static let maxGapFill: Int64 = 10

    private var lastSeq = noSeq
    private var lastFrame: Data?

    /// Call for a new stream or after a disconnect: forgets the position so the next packet is accepted unconditionally.
    func reset() {
        lastSeq = Self.noSeq
        lastFrame = nil
    }

    func decode(_ packet: Data) -> DecodedPacket? {
        let b = [UInt8](packet)
        guard b.count >= Self.header else { return nil }
        let flags = Int(b[0])
        let len = Self.u32(b, 1)
        guard len >= 0, Self.header + len <= b.count else { return nil }
        if flags & PacketFlag.idle != 0 { return DecodedPacket(flags: flags, messages: [], resync: false) }
        if flags & (PacketFlag.transition | PacketFlag.transitionEnd) != 0 { return DecodedPacket(flags: flags, messages: [], resync: false) }
        if len == 0 { return DecodedPacket(flags: flags, messages: [], resync: false) }

        let body = Data(b[Self.header ..< (Self.header + len)])
        let rawData: Data
        if flags & PacketFlag.gzipped != 0 {
            guard let inflated = Gunzip.inflate(body) else { return nil }
            rawData = inflated
        } else {
            rawData = body
        }
        let raw = [UInt8](rawData)
        guard raw.count >= 4 else { return nil }
        let seq = Int64(UInt32(truncatingIfNeeded: Self.u32(raw, 0)))

        let current: Data
        var prev1: Data?
        var prev2: Data?
        if flags & PacketFlag.redundant != 0 {
            var off = 4
            let curLen = Self.u32(raw, off); off += 4
            guard curLen >= 0, off + curLen <= raw.count else { return nil }
            current = Data(raw[off ..< (off + curLen)]); off += curLen
            if off + 4 <= raw.count {
                let p1 = Self.u32(raw, off); off += 4
                if p1 > 0, off + p1 <= raw.count { prev1 = Data(raw[off ..< (off + p1)]) }
                off += max(p1, 0)
            }
            if off + 4 <= raw.count {
                let p2 = Self.u32(raw, off); off += 4
                if p2 > 0, off + p2 <= raw.count { prev2 = Data(raw[off ..< (off + p2)]) }
            }
        } else {
            current = Data(raw[4...])
        }

        var resync = false
        // Start usually begins a new stream, and frameSeq restarts from 0
        if flags & PacketFlag.start != 0, lastSeq != Self.noSeq, seq < lastSeq {
            lastSeq = Self.noSeq
            lastFrame = nil
        }
        if lastSeq != Self.noSeq, seq <= lastSeq { return DecodedPacket(flags: flags, messages: [], resync: false) } // duplicate or late

        var out: [Data] = []
        if lastSeq != Self.noSeq {
            let missed = seq - lastSeq - 1
            if missed > 0 {
                var recovered: [Data] = []
                if missed >= 2, let p2 = prev2 { recovered.append(p2) }
                if missed >= 1, let p1 = prev1 { recovered.append(p1) }
                let unrecoverable = missed - Int64(recovered.count)
                if unrecoverable > Self.maxGapFill || (unrecoverable > 0 && lastFrame == nil) {
                    resync = true
                } else {
                    if unrecoverable > 0, let held = lastFrame { out.append(contentsOf: Array(repeating: held, count: Int(unrecoverable))) }
                    out.append(contentsOf: recovered)
                }
            }
        }
        out.append(current)
        lastSeq = seq
        lastFrame = current
        return DecodedPacket(flags: flags, messages: out, resync: resync)
    }

    private static func u32(_ b: [UInt8], _ off: Int) -> Int {
        guard off + 4 <= b.count else { return -1 }
        let v = UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
        return v > UInt32(Int32.max) ? -1 : Int(v)
    }
}
