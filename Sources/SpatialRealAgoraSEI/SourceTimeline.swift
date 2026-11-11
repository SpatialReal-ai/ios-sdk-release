import Foundation
@_spi(RTC) import SpatialRealSDK

/// 一条流的 Opus 解码器;单测注入假的。
package protocol SourceOpusDecoding: AnyObject {
    /// 一个 Opus 包解出的全部样本(PCM16 单声道 48 kHz),不裁 pre-skip。
    func decode(_ packet: Data) throws -> Data
    func release()
}

extension RtcOpusDecoder: SourceOpusDecoding {}

/// 源时间线往下游(宿主播放器)交的东西。调用顺序:一轮里先有 `turnAudio`(开轮),之后音频和帧交替,最后 `turnEnd`。
@MainActor package protocol SourceTimelineSink: AnyObject {
    /// 这一轮接下来的一段连续 PCM16(48 kHz 单声道),从源样本 0 起不留空洞。
    func turnAudio(_ pcm: Data)
    /// 这一轮接下来的姿态,每条一个 `Message`,从第 0 帧起连续(每帧 1920 个源样本)。
    func turnFrames(_ messages: [Data])
    /// 这一轮的有效音频和姿态都交完了。
    func turnEnd()
    /// 服务端打断了正在播的这一轮:丢掉已排队的。
    func interruptPlayback()
}

/// Agora SEI 里的"源时间线"(照 Web `facade/rtc/source-audio-router.ts`,简化到 iOS 播放器需要的部分)。
///
/// 每条 SEI 都带 `RtcAudioBundle`:流的身份(publication + stream sequence = 一轮)、Opus 包(带解码器样本坐标和有效区间)、
/// 结束标记;同一个 `ServerResponseAnimation` 里的姿态用 `animation_source_sample` 落在同一条样本时钟上。
/// 包和姿态会在很多条 SEI 里重复(冗余 / 突发模式的重发),这里按包序号和样本位置去重、排序,
/// 再从源样本 0 起把连续的 PCM 和姿态交给宿主播放器。播放器以"已播样本数"为时钟取帧,所以到达快于实时(突发)也对得上。
///
/// - 突发(`BOUNDED_BURST_V1`):有音频和第一帧就起播,后面的一次性排进播放器。
/// - 实时节奏(无 profile):先攒 `realtimeStartSamples`(0.4 s)连续音频再起播,吸收网络抖动(同 Web)。
/// - 结束:`RtcAudioEnd(complete)` 且有效样本、姿态都交完 → `turnEnd`。
/// - 打断:`RtcAudioEnd(interrupted)` → `interruptPlayback`;这一条流作废,之后重复来的包不会再把它开起来。
/// - 丢包:后面的包到了而缺的包 `gapWait` 内没补上,用静音占位(保住样本坐标,嘴型不错位)。
@MainActor package final class SourceTimeline {
    package struct Options {
        var frameSamples = 1920
        var realtimeStartSamples = 19200
        /// 有空洞(后面的包已到)时等补包多久,之后静音占位。
        var gapWait: TimeInterval = 0.25
        /// 结束标记已到、尾巴还缺:等多久就按已有的收尾。
        var tailWait: TimeInterval = 3
        /// 没有结束标记、也没有新数据:等多久就按已有的收尾。
        var idleWait: TimeInterval = 10
        var maxPendingStreams = 4
        /// 一轮最多攒多少还没交出去的样本(60 s,和播放器的背压上限一致)。
        var maxPendingSamples = 48000 * 60

        package init() {}
    }

    package struct Stats: Equatable {
        package var carriers = 0, withoutAudio = 0, invalid = 0
        package var streams = 0, turnsEnded = 0, serverInterrupts = 0, stalled = 0
        package var packets = 0, concealedPackets = 0, frames = 0
        package var samplesOut = 0, framesOut = 0
        package var decodeErrors = 0
        /// 解码器给出的样本数和包描述的 decodedSamples 不一致的包(坐标以包描述为准,裁/补齐)。
        package var decodeSizeMismatches = 0
        /// 最近一次不一致:流序号 / 包序号 / 解出的样本数 / 包描述的样本数。
        package var lastDecodeSizeMismatch: String?
    }

    private final class Stream {
        let publication: String
        let sequence: UInt64
        let preSkip: Int
        let burst: Bool
        var packets: [UInt64: RtcSourceMessage.Packet] = [:]
        var nextPacket: UInt64 = 0
        var decoder: SourceOpusDecoding?
        /// 已解码的有效音频的末尾(源样本坐标)。
        var decodedThrough = 0
        /// 已解码、还没交出去的 PCM;开头是源样本 `admitted`。
        var pcm = Data()
        var admitted = 0
        var frames: [Int: Data] = [:]
        var covered = 0
        var end: RtcSourceMessage.End?
        var started = false
        var lastProgress: TimeInterval
        var gapSince: TimeInterval?

        init(publication: String, sequence: UInt64, preSkip: Int, burst: Bool, now: TimeInterval) {
            self.publication = publication
            self.sequence = sequence
            self.preSkip = preSkip
            self.burst = burst
            lastProgress = now
        }
    }

    private unowned let sink: SourceTimelineSink
    private let makeDecoder: () throws -> SourceOpusDecoding
    private let now: () -> TimeInterval
    package let options: Options
    package private(set) var stats = Stats()

    private var publication: String?
    private var active: Stream?
    private var pending: [UInt64: Stream] = [:]
    /// 这个序号及以前的流已结束或作废:它们的重发不再理会。
    private var retiredThrough: Int64 = -1
    /// 见过的最大序号:服务端的打断只可能针对它。
    private var observedThrough: Int64 = -1
    /// 已经交给播放器收尾、可能还在播的那一轮(只记最新的一个)。
    private var playingSequence: UInt64?
    private var handledInterrupt: UInt64?

    package init(sink: SourceTimelineSink, options: Options = Options(), makeDecoder: @escaping () throws -> SourceOpusDecoding, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink
        self.options = options
        self.makeDecoder = makeDecoder
        self.now = now
    }

    package var isTurnOpen: Bool { active?.started == true }
    package var activeSequence: UInt64? { active?.sequence }

    // MARK: - 输入

    /// 一条 SEI 里的一条 Message。`content` = 载体是内容包(不是 Idle / 转场):只有内容包能开一条新流,
    /// 控制包只修补已经见过的流(补包、补结束标记)。
    package func accept(_ message: RtcSourceMessage, content: Bool) {
        stats.carriers += 1
        guard let a = message.audio else { stats.withoutAudio += 1; return }
        guard a.sampleRate == 48000, a.channels == 1, !a.publicationID.isEmpty else { stats.invalid += 1; return }
        let t = now()

        if let current = publication, current != a.publicationID {
            // 形象重新发布了:旧的那条全部作废
            guard content else { return }
            dropAll(interruptPlaying: active?.started == true)
            reset()
        }
        publication = a.publicationID

        if let end = a.end, end.reason == .interrupted {
            serverInterrupted(a.streamSequence)
            return
        }
        if Int64(a.streamSequence) <= retiredThrough { return }

        var stream: Stream
        if let s = active, s.sequence == a.streamSequence {
            stream = s
        } else if let s = pending[a.streamSequence] {
            stream = s
        } else {
            guard content else { return }
            if let s = active, a.streamSequence < s.sequence { return }
            guard pending.count < options.maxPendingStreams else { stats.invalid += 1; return }
            stream = Stream(publication: a.publicationID, sequence: a.streamSequence, preSkip: a.preSkip, burst: a.profile == 1, now: t)
            stats.streams += 1
            observedThrough = max(observedThrough, Int64(a.streamSequence))
            if active == nil { activate(stream) } else { pending[a.streamSequence] = stream }
        }
        guard stream.preSkip == a.preSkip else { stats.invalid += 1; return }

        var progressed = false
        for p in a.packets where p.sequence >= stream.nextPacket && stream.packets[p.sequence] == nil {
            guard p.decodedSamples > 0, p.decodedSamples <= 5760, p.validStart >= p.decodedStart, p.validEnd >= p.validStart,
                  p.validEnd <= p.decodedStart + UInt64(p.decodedSamples), !p.data.isEmpty
            else { stats.invalid += 1; continue }
            stream.packets[p.sequence] = p
            stats.packets += 1
            progressed = true
        }
        if let first = message.animationSourceSample, message.keyframeCount > 0 {
            for i in 0..<message.keyframeCount {
                let start = Int(first) + i * options.frameSamples
                if start < stream.covered || stream.frames[start] != nil { continue }
                if let end = stream.end, start >= Int(end.animationSamples) { continue }
                guard start - stream.covered <= options.maxPendingSamples else { stats.invalid += 1; break }
                stream.frames[start] = message.frameMessage(at: i)
                stats.frames += 1
                progressed = true
            }
        }
        if stream.end == nil, let end = a.end, end.reason == .complete {
            stream.end = end
            stream.frames = stream.frames.filter { $0.key < Int(end.animationSamples) }
            progressed = true
        }
        if progressed { stream.lastProgress = t }
        if stream === active { pump() }
    }

    /// 定时调用(约 10 Hz):空洞静音占位、超时收尾。
    package func tick() {
        guard let s = active else { return }
        pump()
        guard active === s else { return }
        let idle = now() - s.lastProgress
        let wait = s.end != nil ? options.tailWait : options.idleWait
        if idle >= wait {
            stats.stalled += 1
            finish(s, natural: false)
        }
    }

    /// 接入方的打断:把见过的流全部作废(它们的重发不再开轮)。播放器由会话自己打断。
    package func interrupt() {
        retiredThrough = max(retiredThrough, observedThrough)
        dropAll(interruptPlaying: false)
        playingSequence = nil
    }

    /// 形象离开 / 会话结束:全部忘掉,下一条内容包重新开始。
    package func reset() {
        dropAll(interruptPlaying: false)
        publication = nil
        retiredThrough = -1
        observedThrough = -1
        playingSequence = nil
        handledInterrupt = nil
    }

    // MARK: - 内部

    private func serverInterrupted(_ sequence: UInt64) {
        if handledInterrupt == sequence { return }
        if let s = active, s.sequence == sequence {
            handledInterrupt = sequence
            stats.serverInterrupts += 1
            let wasPlaying = s.started || playingSequence != nil
            retire(s)
            active = nil
            playingSequence = nil
            if wasPlaying { sink.interruptPlayback() }
            activateNext()
        } else if let s = pending.removeValue(forKey: sequence) {
            handledInterrupt = sequence
            s.decoder?.release()
            retiredThrough = max(retiredThrough, Int64(sequence))
        } else if playingSequence == sequence, Int64(sequence) == observedThrough {
            // 已经全交给播放器、可能还在播;只有它还是最新的一轮时才算数(否则是过时的重发)
            handledInterrupt = sequence
            stats.serverInterrupts += 1
            playingSequence = nil
            sink.interruptPlayback()
        } else if Int64(sequence) > retiredThrough {
            // 还没见过内容就被打断了:记成作废,之后的重发不开轮
            handledInterrupt = sequence
            retiredThrough = Int64(sequence)
            observedThrough = max(observedThrough, Int64(sequence))
        }
    }

    private func activate(_ s: Stream) {
        active = s
        do {
            s.decoder = try makeDecoder()
        } catch {
            stats.decodeErrors += 1
        }
    }

    private func activateNext() {
        guard active == nil, let seq = pending.keys.min(), let next = pending.removeValue(forKey: seq) else { return }
        activate(next)
        pump()
    }

    private func pump() {
        guard let s = active else { return }
        decodeAvailable(s)
        concealGapIfDue(s)
        if !s.started {
            let available = s.pcm.count / 2
            let complete = s.end.map { s.decodedThrough >= Int($0.sourceSamples) } ?? false
            let need = s.burst ? 1 : options.realtimeStartSamples
            guard available > 0, available >= need || complete, s.frames[0] != nil || complete else { return }
            s.started = true
        }
        deliver(s)
        if let end = s.end, s.admitted >= Int(end.sourceSamples), s.covered >= Int(end.animationSamples) - (options.frameSamples - 1) {
            finish(s, natural: true)
        }
    }

    private func decodeAvailable(_ s: Stream) {
        while let p = s.packets.removeValue(forKey: s.nextPacket) {
            s.nextPacket += 1
            s.gapSince = nil
            var raw = Data()
            if let decoder = s.decoder {
                do { raw = try decoder.decode(p.data) } catch { stats.decodeErrors += 1 }
            }
            // 坐标以包描述为准:解码器多给少给都裁/补到 decodedSamples
            let want = p.decodedSamples * 2
            if raw.count != want, s.decoder != nil {
                stats.decodeSizeMismatches += 1
                stats.lastDecodeSizeMismatch = "stream \(s.sequence) packet \(p.sequence): \(raw.count / 2) of \(p.decodedSamples) (valid \(p.validStart)..<\(p.validEnd), start \(p.decodedStart), \(p.data.count) B)"
            }
            if raw.count > want { raw = raw.prefix(want) } else if raw.count < want { raw.append(Data(count: want - raw.count)) }
            guard p.validEnd > p.validStart else { continue }
            let validStart = max(Int(p.validStart), s.preSkip)
            let validEnd = Int(p.validEnd)
            guard validEnd > validStart else { continue }
            var from = validStart - s.preSkip
            let to = validEnd - s.preSkip
            if from > s.decodedThrough { appendPcm(s, Data(count: (from - s.decodedThrough) * 2)) }
            if from < s.decodedThrough { from = s.decodedThrough }
            guard to > from else { continue }
            let offset = (from + s.preSkip - Int(p.decodedStart)) * 2
            appendPcm(s, raw.subdata(in: (raw.startIndex + offset)..<(raw.startIndex + offset + (to - from) * 2)))
            s.decodedThrough = to
        }
    }

    private func appendPcm(_ s: Stream, _ bytes: Data) {
        guard s.pcm.count / 2 + bytes.count / 2 <= options.maxPendingSamples else { stats.invalid += 1; return }
        s.pcm.append(bytes)
        s.decodedThrough = s.admitted + s.pcm.count / 2
    }

    /// 缺 nextPacket 而后面的包已到:等 `gapWait` 补包,之后用静音把坐标补到下一个包,解码继续。
    private func concealGapIfDue(_ s: Stream) {
        guard s.packets[s.nextPacket] == nil, let later = s.packets.keys.min() else { s.gapSince = nil; return }
        let t = now()
        guard let since = s.gapSince else { s.gapSince = t; return }
        guard t - since >= options.gapWait, let q = s.packets[later] else { return }
        let target = max(Int(q.validStart), s.preSkip) - s.preSkip
        if target > s.decodedThrough { appendPcm(s, Data(count: (target - s.decodedThrough) * 2)) }
        stats.concealedPackets += Int(later - s.nextPacket)
        s.nextPacket = later
        s.gapSince = nil
        decodeAvailable(s)
    }

    private func deliver(_ s: Stream) {
        let limit = s.end.map { Int($0.sourceSamples) } ?? Int.max
        let n = min(s.pcm.count / 2, max(0, limit - s.admitted))
        if n > 0 {
            let chunk = s.pcm.prefix(n * 2)
            s.pcm = Data(s.pcm.dropFirst(n * 2))
            s.admitted += n
            stats.samplesOut += n
            sink.turnAudio(Data(chunk))
        }
        if s.admitted >= limit, !s.pcm.isEmpty { s.pcm = Data() }
        var batch: [Data] = []
        while let f = s.frames.removeValue(forKey: s.covered) {
            batch.append(f)
            s.covered += options.frameSamples
        }
        if !batch.isEmpty {
            stats.framesOut += batch.count
            sink.turnFrames(batch)
        }
    }

    /// 收尾:正常结束(全交完)或超时(按已有的)。没起播过又什么都没有的流直接作废。
    private func finish(_ s: Stream, natural: Bool) {
        if !natural, !s.started, s.pcm.isEmpty {
            retire(s)
            active = nil
            activateNext()
            return
        }
        if !s.started {
            s.started = true
            deliver(s)
        }
        sink.turnEnd()
        stats.turnsEnded += 1
        retire(s)
        active = nil
        playingSequence = s.sequence
        activateNext()
    }

    private func retire(_ s: Stream) {
        s.decoder?.release()
        s.decoder = nil
        retiredThrough = max(retiredThrough, Int64(s.sequence))
    }

    private func dropAll(interruptPlaying: Bool) {
        if let s = active { s.decoder?.release() }
        for s in pending.values { s.decoder?.release() }
        active = nil
        pending.removeAll()
        if interruptPlaying { sink.interruptPlayback() }
    }
}
