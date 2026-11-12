import Foundation

/// Turn gate: derives speaking turns from the animation packet flags.
///
/// The server's packet stream has no notion of a turn, only flags. Start opens a turn (if Start is lost, the
/// first content frame opens it) and End closes it. At the normal end of a turn the server doesn't send End:
/// content stops, ~0.8 s of TransitionEnd packets follow, then idle heartbeats. So the first TransitionEnd is
/// treated as the end of speech, with Idle as the fallback. Audio is forwarded only while the gate is open.
@MainActor protocol TurnSink: AnyObject {
    func open()
    func audio(_ pcm: Data, end: Bool)
    func frames(_ messages: [Data])
    func close()
}

/// Main-actor only (the session's event loop and the host-mode player both run on the main actor).
@MainActor final class TurnGate {
    private let sink: TurnSink
    private(set) var isOpen = false
    /// Set after an interrupt: the tail of the interrupted utterance (a re-sent Start with no frames) must not reopen the turn.
    private(set) var isSuppressed = false

    init(sink: TurnSink) { self.sink = sink }

    func frame(_ flags: Int, _ messages: [Data]) {
        let isIdle = flags & PacketFlag.idle != 0
        let isContent = !isIdle && flags & (PacketFlag.transition | PacketFlag.transitionEnd) == 0
        if isIdle || flags & PacketFlag.transitionEnd != 0 {
            if isOpen { closeTurn() }
            isSuppressed = false
            return
        }
        if !isContent { return } // a transition-start packet carries nothing for us (the player runs transitions itself)
        if isSuppressed {
            if flags & PacketFlag.start == 0 || messages.isEmpty { return }
            isSuppressed = false
        }
        if !isOpen, flags & PacketFlag.start != 0 || !messages.isEmpty { openTurn() }
        if isOpen, !messages.isEmpty { sink.frames(messages) }
        if isOpen, flags & PacketFlag.end != 0 { closeTurn() }
    }

    func audio(_ pcm: Data) {
        if pcm.isEmpty { return }
        if isOpen { sink.audio(pcm, end: false) }
    }

    func reset() {
        if isOpen { closeTurn() }
    }

    func interrupt() {
        reset()
        isSuppressed = true
    }

    private func openTurn() {
        isOpen = true
        sink.open()
    }

    private func closeTurn() {
        isOpen = false
        sink.audio(Data(), end: true)
        sink.close()
    }
}
