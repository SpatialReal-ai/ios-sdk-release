import Foundation
import os

/// Where the bot's voice is played from.
public enum PipecatVoiceRoute: Sendable, Equatable {
    /// Daily plays the bot's audio track (before audio mode starts, and whenever it stops).
    case call
    /// The avatar plays the bot's voice from the audio the processor sends with the animation;
    /// the bot's audio track is unsubscribed.
    case avatar
}

/// Host-mode playback, one turn at a time (the session's Ogg Opus Host player).
@MainActor protocol HostTurnPlayer: AnyObject {
    /// Opens a turn; nil when the session cannot play now.
    func beginTurn() -> String?
    func yieldAudio(_ slice: Data, turnID: String)
    func yieldFrames(_ frames: [Data], turnID: String)
    func setAudioOnly(turnID: String)
    /// The turn's end-of-audio flag; the next turn can be opened after this.
    func endTurn(turnID: String)
    /// Drops every turn the player holds.
    func interrupt()
}

/// The call side: the bot's audio track and the message channel back to the processor.
@MainActor protocol BotAudioLink: AnyObject {
    /// Sends `AudioRequest` to the processor; false when the transport refused it (no call, or the
    /// call has ended), so nothing will answer it.
    func sendAudioRequest() -> Bool
    func setBotAudioSubscribed(_ subscribed: Bool)
}

/// The audio-mode state machine: which turns the avatar plays, and when the bot is heard on its track.
///
/// - Before audio mode, and whenever it breaks, the bot is heard through Daily's audio track.
/// - After `AudioMode(active)`, the track is unsubscribed at the first quiet point: every turn that is
///   playing on the track has ended and the track has been silent for 300 ms. A turn announced while the
///   phone is still on the track plays on the track, even when it also sends audio.
/// - Host turns play in announcement order. A turn's audio is held until its `turn_start`; the Host
///   turn gets its end-of-audio flag only once both its last audio and its last animation segment are in
///   (or the turn is audio-only), so the frame gate never truncates audio that is still waiting for
///   animation. Frames are routed by turn id, so they keep reaching a turn after the next one opened.
/// - Lost messages send the phone back to the track and ask for audio mode again: a `seq` gap, a turn
///   that ends without its `turn_start` or its last audio, animation for a turn it never heard of (its
///   `turn_start` was lost), or the next turn's audio before this turn's last audio. Daily drops app
///   messages while it reconnects and its reconnects are not reliably visible from the app, so these
///   checks, not a reconnect event, are what catch it.
///   `AudioMode(inactive)` goes back to the track without asking again.
/// - When the next Host turn is announced, an earlier turn whose audio is complete gets its end flag
///   then, so a lost `frames.end` / `turn_end` cannot hold every later turn.
/// No timers of its own: it advances on messages and on the bot's audio level (Daily reports it every
/// 100 ms while the track is subscribed).
@MainActor final class TurnRouter {
    static let quietSeconds: TimeInterval = 0.3
    /// Daily's 0...1 audio level below which the bot's track counts as silent.
    static let silenceLevel: Float = 0.01

    private enum Mode: Equatable {
        case off
        case requested
        case on(firstTurnID: String)
    }

    private final class HostTurn {
        let id: String
        var playerID: String?
        var pendingAudio: [Data] = []
        var pendingFrames: [Data] = []
        var nextSeq = 0
        var audioEnded = false
        var framesEnded = false
        var audioOnly = false
        var framesBroken = false
        var expectedSegment = 0
        var chunks: [Data] = []
        var closed = false

        init(id: String) { self.id = id }
        var isOpen: Bool { playerID != nil }
    }

    private let player: HostTurnPlayer
    private let link: BotAudioLink
    private let logger = Logger(subsystem: "ai.spatialreal", category: "PipecatTurnRouter")

    private(set) var route: PipecatVoiceRoute = .call
    var onRouteChange: ((PipecatVoiceRoute) -> Void)?

    private var mode: Mode = .off
    private var isBotReady = false
    private var active = false
    private var silentSince: TimeInterval?
    /// Turns announced while the phone was on the track: they play there until their end.
    private var trackTurns: Set<String> = []
    /// Audio (and any frames) of mode turns whose `turn_start` has not arrived yet.
    private var unannounced: [String: HostTurn] = [:]
    /// Announced Host turns in announcement order, until their `turn_end` / `turn_abort`.
    private var queue: [HostTurn] = []
    /// Turns handed to the player since the last interrupt (it may still be playing them).
    private var inPlayer: Set<String> = []
    /// Turns this router is done with (ended, aborted or dropped): their late messages are expected.
    private var finished: [String] = []

    init(player: HostTurnPlayer, link: BotAudioLink) {
        self.player = player
        self.link = link
    }

    // MARK: - Inputs

    /// The session went live: audio mode can be requested once the bot is ready.
    func activate() {
        active = true
        requestIfReady()
    }

    /// Pipecat's client-ready handshake completed.
    func botReady() {
        isBotReady = true
        requestIfReady()
    }

    /// The transport reconnected; app messages may have been lost meanwhile.
    func transportReconnected() {
        guard active else { return }
        logger.info("transport reconnected: back to the bot's audio track, audio mode requested again")
        backToTrack(requestAgain: true)
    }

    /// The bot is gone (left the call); a new bot starts from scratch.
    func botLeft() {
        guard active else { return }
        backToTrack(requestAgain: false)
        isBotReady = false
    }

    /// The session ended: drop everything and give the voice back to the call. The bot's readiness
    /// belonged to that call, so a session started again waits for the next call's bot-ready.
    func deactivate() {
        dropAll(interruptPlayer: false)
        setRoute(.call)
        mode = .off
        isBotReady = false
        active = false
    }

    /// The bot's audio level from Daily (0...1), about every 100 ms.
    func botAudioLevel(_ level: Float, now: TimeInterval) {
        guard active, route == .call else { return }
        if level < Self.silenceLevel {
            if silentSince == nil { silentSince = now }
        } else {
            silentSince = nil
        }
        switchIfQuiet(now: now)
    }

    func handle(_ message: AvatarMessage, now: TimeInterval) {
        guard active else { return }
        switch message.payload {
        case let .audioMode(m)?:
            guard m.active else {
                logger.info("audio mode stopped by the processor: back to the bot's audio track")
                backToTrack(requestAgain: false)
                return
            }
            mode = .on(firstTurnID: m.firstTurnID)
            switchIfQuiet(now: now)
        case let .audio(audio)?:
            onAudio(audio)
        case let .turnStart(m)?:
            onTurnStart(m.turnID, degraded: m.degraded, now: now)
        case let .frames(frames)?:
            if let t = hostTurn(frames.turnID) ?? unannounced[frames.turnID] {
                addFrames(t, frames)
            } else {
                checkKnown(frames.turnID, "animation")
            }
        case let .turnAudioOnly(m)?:
            guard let t = hostTurn(m.turnID) else {
                checkKnown(m.turnID, "turn_audio_only")
                return
            }
            makeAudioOnly(t)
        case let .turnEnd(m)?:
            onTurnEnd(m.turnID, now: now)
        case let .turnAbort(m)?:
            onTurnAbort(m.turnID, now: now)
        case .turnOnsets?, .turnEnvelope?, .state?, nil:
            break // Host mode plays sample-exact: no alignment hints needed
        }
    }

    // MARK: - Mode and route

    private func requestIfReady() {
        guard active, isBotReady, mode == .off else { return }
        mode = .requested
        guard link.sendAudioRequest() else {
            // Nothing will answer a request that never left: the next bot-ready or reconnect asks again.
            logger.info("the audio request could not be sent; it is sent again at the next bot-ready or reconnect")
            mode = .off
            return
        }
    }

    private var isQuiet: Bool {
        guard case .on = mode, trackTurns.isEmpty, let s = silentSince else { return false }
        // Daily's level events come about every 100 ms; allow for their jitter.
        return lastNow - s >= Self.quietSeconds - 0.02
    }

    private var lastNow: TimeInterval = 0

    private func switchIfQuiet(now: TimeInterval) {
        lastNow = now
        guard route == .call, isQuiet else { return }
        logger.info("quiet point: the avatar plays the bot's voice from now on")
        setRoute(.avatar)
        pump()
    }

    private func setRoute(_ r: PipecatVoiceRoute) {
        guard route != r else { return }
        route = r
        if r == .call { silentSince = nil }
        link.setBotAudioSubscribed(r == .call)
        onRouteChange?(r)
    }

    /// Abort the turn being received, hear the bot on its track again, and (after a
    /// reconnect or a broken stream) ask for audio mode again.
    private func backToTrack(requestAgain: Bool) {
        dropAll(interruptPlayer: true)
        setRoute(.call)
        mode = .off
        if requestAgain { requestIfReady() }
    }

    private func dropAll(interruptPlayer: Bool) {
        if interruptPlayer, !inPlayer.isEmpty { player.interrupt() }
        for id in queue.map(\.id) + Array(unannounced.keys) + Array(trackTurns) { markFinished(id) }
        inPlayer.removeAll()
        queue.removeAll()
        unannounced.removeAll()
        trackTurns.removeAll()
    }

    private func streamBroken(_ why: String) {
        logger.warning("bot audio stream broken (\(why, privacy: .public)): back to the bot's audio track")
        backToTrack(requestAgain: true)
    }

    // MARK: - Turns

    private func hostTurn(_ id: String) -> HostTurn? { queue.first { $0.id == id } }

    private func markFinished(_ id: String) {
        guard !finished.contains(id) else { return }
        finished.append(id)
        if finished.count > 64 { finished.removeFirst(finished.count - 64) }
    }

    /// While the avatar has the voice, a message for a turn this router never heard of means its
    /// `turn_start` (and its audio) was lost: Daily drops app messages while it reconnects, and its
    /// reconnects are not reliably visible from the app.
    private func checkKnown(_ id: String, _ what: String) {
        guard route == .avatar, !trackTurns.contains(id), !finished.contains(id) else { return }
        streamBroken("\(what) for turn \(id), whose turn_start never came")
    }

    private func onAudio(_ a: Pipecat_V1_Audio) {
        if let t = hostTurn(a.turnID) {
            appendAudio(t, a)
            return
        }
        if trackTurns.contains(a.turnID) || finished.contains(a.turnID) { return } // on the track, or done with
        if unannounced[a.turnID] == nil, route == .avatar, let open = queue.first(where: { !$0.audioEnded }) {
            // A turn's audio always ends before the next turn's begins (or the turn is aborted first).
            streamBroken("turn \(a.turnID) began before turn \(open.id)'s last audio")
            return
        }
        let t = unannounced[a.turnID] ?? HostTurn(id: a.turnID)
        unannounced[a.turnID] = t
        appendAudio(t, a)
    }

    private func appendAudio(_ t: HostTurn, _ a: Pipecat_V1_Audio) {
        guard !t.audioEnded else { return }
        guard Int(a.seq) == t.nextSeq else {
            streamBroken("turn \(t.id): audio seq \(a.seq), expected \(t.nextSeq)")
            return
        }
        t.nextSeq += 1
        if let pid = t.playerID {
            player.yieldAudio(a.data, turnID: pid)
        } else {
            t.pendingAudio.append(a.data)
        }
        if a.end {
            t.audioEnded = true
            closeIfComplete(t)
        }
    }

    private func onTurnStart(_ id: String, degraded: Bool, now: TimeInterval) {
        lastNow = now
        guard hostTurn(id) == nil, !trackTurns.contains(id) else { return }
        let buffered = unannounced.removeValue(forKey: id)
        var isModeTurn = buffered != nil
        if case let .on(first) = mode, id == first { isModeTurn = true }

        guard isModeTurn else {
            trackTurns.insert(id)
            if route == .avatar {
                // A turn that began before audio mode, announced late: its voice is on the track.
                logger.info("turn \(id, privacy: .public) plays on the bot's audio track")
                setRoute(.call)
            }
            return
        }
        if route == .call {
            switchIfQuiet(now: now)
            if route == .call {
                // Not quiet: this turn's voice reaches the track; hearing it there avoids a double voice.
                trackTurns.insert(id)
                return
            }
        }
        let t = buffered ?? HostTurn(id: id)
        if degraded { t.audioOnly = true }
        // The next turn's animation comes after this one's: an earlier turn whose audio is complete gets
        // its end flag now (a lost frames.end / turn_end would otherwise hold every later turn). Its
        // frames keep reaching it by turn id if any are still on the way.
        for earlier in queue where earlier.isOpen && !earlier.closed && earlier.audioEnded {
            earlier.closed = true
            player.endTurn(turnID: earlier.playerID!)
        }
        queue.append(t)
        pump()
    }

    private func addFrames(_ t: HostTurn, _ f: Pipecat_V1_Frames) {
        guard !t.framesBroken, !t.framesEnded else { return }
        guard Int(f.segmentSeq) == t.expectedSegment, Int(f.chunkIndex) == t.chunks.count else {
            // A lost chunk or segment would shift every later frame: play the rest as audio only.
            logger.warning("turn \(t.id, privacy: .public): animation segment \(f.segmentSeq) chunk \(f.chunkIndex) out of order; audio only from here")
            t.framesBroken = true
            makeAudioOnly(t)
            return
        }
        t.chunks.append(f.data)
        guard t.chunks.count >= max(1, Int(f.chunkCount)) else { return }
        var segment = Data()
        for c in t.chunks { segment.append(c) }
        t.chunks.removeAll()
        t.expectedSegment += 1
        if t.audioOnly {
            // audio only already: frames are no longer used
        } else if let pid = t.playerID {
            player.yieldFrames([segment], turnID: pid)
        } else {
            t.pendingFrames.append(segment)
        }
        if f.end {
            t.framesEnded = true
            closeIfComplete(t)
        }
    }

    private func makeAudioOnly(_ t: HostTurn) {
        guard !t.audioOnly else { return }
        t.audioOnly = true
        t.pendingFrames.removeAll()
        if let pid = t.playerID, !t.closed { player.setAudioOnly(turnID: pid) }
        closeIfComplete(t)
    }

    private func closeIfComplete(_ t: HostTurn) {
        guard let pid = t.playerID, !t.closed, t.audioEnded, t.framesEnded || t.audioOnly else { return }
        t.closed = true
        player.endTurn(turnID: pid)
        pump()
    }

    /// Opens the next announced Host turn once the previous one is closed.
    private func pump() {
        guard route == .avatar else { return }
        while let next = queue.first(where: { !$0.closed }), !next.isOpen {
            guard let pid = player.beginTurn() else { return }
            next.playerID = pid
            inPlayer.insert(next.id)
            if next.audioOnly { player.setAudioOnly(turnID: pid) }
            for a in next.pendingAudio { player.yieldAudio(a, turnID: pid) }
            next.pendingAudio.removeAll()
            if !next.audioOnly, !next.pendingFrames.isEmpty { player.yieldFrames(next.pendingFrames, turnID: pid) }
            next.pendingFrames.removeAll()
            closeIfComplete(next) // may open the one after it
            if !next.closed { return }
        }
    }

    private func onTurnEnd(_ id: String, now: TimeInterval) {
        lastNow = now
        if trackTurns.remove(id) != nil {
            markFinished(id)
            trackTurnFinished(now: now)
            return
        }
        if unannounced.removeValue(forKey: id) != nil {
            // A mode turn always gets its turn_start before its turn_end: it was lost.
            streamBroken("turn \(id) ended without its turn_start")
            return
        }
        guard let t = hostTurn(id) else { return }
        guard t.audioEnded else {
            streamBroken("turn \(id) ended without its last audio")
            return
        }
        if t.isOpen, !t.closed {
            // The room finished it; the rest of its animation is not coming.
            makeAudioOnly(t)
        }
        if t.closed {
            queue.removeAll { $0 === t }
            inPlayer.remove(id)
            markFinished(id)
        }
        // A turn still waiting to open (the phone is behind) stays queued and plays.
    }

    /// `turn_end` / `turn_abort` leave the bot before the track's tail reaches the phone: the 300 ms of
    /// silence are counted from here.
    private func trackTurnFinished(now: TimeInterval) {
        lastNow = now
        silentSince = nil
    }

    private func onTurnAbort(_ id: String, now: TimeInterval) {
        lastNow = now
        if trackTurns.remove(id) != nil {
            markFinished(id)
            trackTurnFinished(now: now)
            return
        }
        markFinished(id)
        if unannounced.removeValue(forKey: id) != nil { return } // aborted before turn_start: drop its buffered audio
        guard let t = hostTurn(id) else { return }
        if inPlayer.contains(id) {
            // Host mode's interrupt() drops every turn it holds.
            player.interrupt()
            for gone in queue where inPlayer.contains(gone.id) { markFinished(gone.id) }
            queue.removeAll { inPlayer.contains($0.id) }
            inPlayer.removeAll()
        } else {
            queue.removeAll { $0 === t }
        }
        pump()
    }
}
