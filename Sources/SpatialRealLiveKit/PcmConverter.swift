import AVFoundation
import Foundation

/// 把 LiveKit 远端音频渲染回调给的 `AVAudioPCMBuffer`(Float32 或 Int16,任意声道数、任意采样率)
/// 转成宿主模式播放器要的 PCM16 单声道、小端、固定采样率;按 `chunkMs` 攒成块再交出。
/// 回调来自音频线程,内部用锁串行。
final class PcmConverter: @unchecked Sendable {
    private let targetRate: Int
    private let chunkBytes: Int
    private let onChunk: @Sendable (Data) -> Void
    private let lock = NSLock()

    private var pending = Data()
    private var lastSample = 0
    private var phase = 0.0
    private var sourceRate = 0

    init(targetRate: Int, chunkMs: Int = 40, onChunk: @escaping @Sendable (Data) -> Void) {
        self.targetRate = targetRate
        chunkBytes = targetRate * chunkMs / 1000 * 2
        self.onChunk = onChunk
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        var mono = [Int16](repeating: 0, count: frames)
        if let f = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let p = f[0]
                for i in 0 ..< frames {
                    var acc: Float = 0
                    for c in 0 ..< channels { acc += p[i * channels + c] }
                    mono[i] = Self.clamp(acc / Float(channels) * 32767)
                }
            } else {
                for i in 0 ..< frames {
                    var acc: Float = 0
                    for c in 0 ..< channels { acc += f[c][i] }
                    mono[i] = Self.clamp(acc / Float(channels) * 32767)
                }
            }
        } else if let s = buffer.int16ChannelData {
            if buffer.format.isInterleaved {
                let p = s[0]
                for i in 0 ..< frames {
                    var acc = 0
                    for c in 0 ..< channels { acc += Int(p[i * channels + c]) }
                    mono[i] = Int16(acc / channels)
                }
            } else {
                for i in 0 ..< frames {
                    var acc = 0
                    for c in 0 ..< channels { acc += Int(s[c][i]) }
                    mono[i] = Int16(acc / channels)
                }
            }
        } else {
            return
        }
        push(mono, sampleRate: Int(buffer.format.sampleRate))
    }

    func push(_ mono: [Int16], sampleRate: Int) {
        lock.lock(); defer { lock.unlock() }
        let out = sampleRate == targetRate ? mono : resample(mono, rate: sampleRate)
        out.withUnsafeBufferPointer { p in
            pending.append(UnsafeBufferPointer(start: UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: UInt8.self), count: p.count * 2))
        }
        while pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            onChunk(Data(chunk))
        }
    }

    /// 轨道没了 / 回合结束时把不满一块的尾巴交出去。
    func flush() {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        let tail = pending
        pending = Data()
        onChunk(tail)
    }

    private func resample(_ input: [Int16], rate: Int) -> [Int16] {
        if rate != sourceRate {
            sourceRate = rate
            phase = 0
            lastSample = 0
        }
        let step = Double(rate) / Double(targetRate)
        var out: [Int16] = []
        out.reserveCapacity(input.count * targetRate / rate + 2)
        // 位置以 input 索引计;-1 代表上一块最后一个样本。按序号乘步长,不累加,避免浮点漂移多出一个样本
        let start = phase - 1.0
        var k = 0
        while true {
            let pos = start + Double(k) * step
            if pos + 1.0 >= Double(input.count) { break }
            let i0 = Int(pos.rounded(.down))
            let frac = pos - Double(i0)
            let s0 = i0 < 0 ? lastSample : Int(input[i0])
            let s1 = Int(input[i0 + 1])
            out.append(Int16(clamping: s0 + Int((Double(s1 - s0) * frac).rounded(.towardZero))))
            k += 1
        }
        phase = (start + Double(k) * step) - Double(input.count - 1)
        lastSample = Int(input[input.count - 1])
        return out
    }

    private static func clamp(_ v: Float) -> Int16 {
        Int16(max(-32768, min(32767, v.rounded(.towardZero))))
    }
}
