import Foundation

/// 回合门限,照搬 Web `facade/rtc/turn-gate.ts`。
///
/// egress 的包流没有"回合"概念,只有 flags:Start 开回合(Start 丢了就由第一个内容帧开),
/// End 关;正常一轮结束时 egress 不发 End,而是内容停、发 ~0.8 s TransitionEnd、再发空闲心跳,
/// 所以第一个 TransitionEnd 就当作说完了;Idle 兜底。门开着时音频才往下送。
@MainActor protocol TurnSink: AnyObject {
    func open()
    func audio(_ pcm: Data, end: Bool)
    func frames(_ messages: [Data])
    func close()
}

/// 只在主线程上用(会话的事件循环和宿主播放器都在主 actor)。
@MainActor final class TurnGate {
    private let sink: TurnSink
    private(set) var isOpen = false
    /// 打断之后:同一句被切断的尾巴(Start 重发、无帧)不能把回合重新打开。
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
        if !isContent { return } // 转场开始包对我们没有内容(播放器自己做转场)
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
