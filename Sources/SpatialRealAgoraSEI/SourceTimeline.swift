import Foundation
@_spi(RTC) import SpatialRealSDK

/// Opus decoder for one stream; unit tests inject a fake.
package protocol SourceOpusDecoding: AnyObject {
    /// All samples decoded from one Opus packet (PCM16 mono, 48 kHz), without trimming pre-skip.
    func decode(_ packet: Data) throws -> Data
    func release()
}

extension RtcOpusDecoder: SourceOpusDecoding {}

/// What the source timeline delivers downstream (to the host player). Call order within a turn: `turnAudio` first
/// (opens the turn), then audio and frames interleaved, then `turnEnd`.
@MainActor package protocol SourceTimelineSink: AnyObject {
    /// The next contiguous run of PCM16 (48 kHz mono) for this turn, gap-free from source sample 0.
    func turnAudio(_ pcm: Data)
    /// The next poses for this turn, one `Message` each, contiguous from frame 0 (1920 source samples per frame).
    func turnFrames(_ messages: [Data])
    /// All valid audio and poses for this turn have been delivered.
    func turnEnd()
    /// The server interrupted the turn that is playing: drop whatever is queued.
    func interruptPlayback()
}

/// The source timeline carried in Agora SEI, reduced to what the host player needs.
///
/// Every SEI carries an `RtcAudioBundle`: the stream identity (publication + stream sequence = one turn), Opus packets
/// (with decoder sample coordinates and a valid range), and an end marker. Poses in the same `ServerResponseAnimation`
/// sit on the same sample clock via `animation_source_sample`. Packets and poses repeat across many SEI messages
/// (redundancy and burst-mode retransmission), so this type deduplicates and orders them by packet sequence and sample
/// position, then hands contiguous PCM and poses to the host player starting at source sample 0. The player picks
/// frames by samples played, so data arriving faster than real time (burst) stays in sync.
///
/// - Burst (`BOUNDED_BURST_V1`): playback starts once there is audio and the first frame; the rest is queued in the
///   player at once.
/// - Real-time pacing (no profile): buffers `realtimeStartSamples` (0.4 s) of contiguous audio before starting, to
///   absorb network jitter.
/// - End: `RtcAudioEnd(complete)` and all valid samples and poses delivered → `turnEnd`.
/// - Interrupt: `RtcAudioEnd(interrupted)` → `interruptPlayback`; the stream is retired and later duplicate packets do
///   not reopen it.
/// - Packet loss: if later packets have arrived and a missing one is not filled within `gapWait`, it is replaced with
///   silence (keeps sample coordinates so lip sync does not drift).
@MainActor package final class SourceTimeline {
    package struct Options {
        var frameSamples = 1920
        var realtimeStartSamples = 19200
        /// How long to wait for a missing packet (when later packets have arrived) before filling with silence.
        var gapWait: TimeInterval = 0.25
        /// End marker received but the tail is incomplete: how long to wait before finishing with what is there.
        var tailWait: TimeInterval = 3
        /// No end marker and no new data: how long to wait before finishing with what is there.
        var idleWait: TimeInterval = 10
        var maxPendingStreams = 4
        /// Maximum undelivered samples buffered per turn (60 s, matching the player's backpressure limit).
        var maxPendingSamples = 48000 * 60

        package init() {}
    }

    package struct Stats: Equatable {
        package var carriers = 0, withoutAudio = 0, invalid = 0
        package var streams = 0, turnsEnded = 0, serverInterrupts = 0, stalled = 0
        package var packets = 0, concealedPackets = 0, frames = 0
        package var samplesOut = 0, framesOut = 0
        package var decodeErrors = 0
        /// Packets where the decoder's sample count differs from the packet's `decodedSamples` (the packet's value
        /// wins; output is trimmed or zero-padded).
        package var decodeSizeMismatches = 0
        /// Most recent mismatch: stream sequence / packet sequence / samples decoded / samples declared.
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
        /// End of the decoded valid audio (source sample coordinate).
        var decodedThrough = 0
        /// Decoded PCM not yet delivered; it starts at source sample `admitted`.
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
    /// Streams up to and including this sequence have ended or been retired; their retransmissions are ignored.
    private var retiredThrough: Int64 = -1
    /// Highest sequence seen; a server interrupt can only target this one.
    private var observedThrough: Int64 = -1
    /// The turn already handed to the player to finish, which may still be playing (only the latest is kept).
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

    // MARK: - Input

    /// One Message from an SEI. `content` means the carrier is a content packet (not Idle / Transition): only content
    /// packets can open a new stream; control packets only patch streams already seen (missing packets, end markers).
    package func accept(_ message: RtcSourceMessage, content: Bool) {
        stats.carriers += 1
        guard let a = message.audio else { stats.withoutAudio += 1; return }
        guard a.sampleRate == 48000, a.channels == 1, !a.publicationID.isEmpty else { stats.invalid += 1; return }
        let t = now()

        if let current = publication, current != a.publicationID {
            // The avatar republished: retire everything from the old publication.
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

    /// Call periodically (about 10 Hz): fills gaps with silence and finishes stalled turns.
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

    /// Client-side interrupt: retires every stream seen so far (their retransmissions do not open a turn). The session
    /// interrupts the player itself.
    package func interrupt() {
        retiredThrough = max(retiredThrough, observedThrough)
        dropAll(interruptPlaying: false)
        playingSequence = nil
    }

    /// Avatar left or session ended: forget everything; the next content packet starts over.
    package func reset() {
        dropAll(interruptPlaying: false)
        publication = nil
        retiredThrough = -1
        observedThrough = -1
        playingSequence = nil
        handledInterrupt = nil
    }

    // MARK: - Internals

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
            // Fully handed to the player and possibly still playing; counts only while it is still the latest turn
            // (otherwise it is a stale retransmission).
            handledInterrupt = sequence
            stats.serverInterrupts += 1
            playingSequence = nil
            sink.interruptPlayback()
        } else if Int64(sequence) > retiredThrough {
            // Interrupted before any content was seen: mark it retired so later retransmissions do not open a turn.
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
            // The packet's coordinates win: trim or zero-pad decoder output to `decodedSamples`.
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

    /// `nextPacket` is missing but later packets have arrived: wait `gapWait` for it, then fill with silence up to the
    /// next available packet and continue decoding.
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

    /// Finishes a turn: naturally (everything delivered) or on timeout (with what is there). A stream that never
    /// started and has nothing buffered is simply retired.
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
